-- Most of this has been lifted from NT Eyes.
-- Table of characters and their temp info.
THERMCharacters = {}
-- Cold
NTTHERM.ExtremeHypothermiaScaling = 1.3
NTTHERM.MediumHypothermiaScaling = 1.2
NTTHERM.LowHypothermiaScaling = 1
-- Hot
NTTHERM.ExtremeHyperthermiaScaling = 1.1
NTTHERM.MediumHyperthermiaScaling = 1.05
NTTHERM.LowHyperthermiaScaling = 1

local Limbs = {LimbType.RightArm,LimbType.LeftArm,LimbType.LeftLeg,LimbType.RightLeg}
-- Function used to take two limbs and apply the heat difference to both.
local function ApplyHeatDifference(character, ToLimbTemp, ToLimbType, FromLimbTemp, FromLimbType)
	local ClampedArteriesResistance = 1
	if HF.GetAfflictionStrengthLimb(character, FromLimbType, "arteriesclamp", 0) > 0 or HF.GetAfflictionStrengthLimb(character, ToLimbType, "arteriesclamp", 0) > 0 then
		-- Drastically reduces the amount of heat transferred when having clamped arteries.
		ClampedArteriesResistance = 3
	end
	-- Make sure the temperature isn't zero. Else temperature shouldn't be added and or removed.
	if FromLimbTemp > 1 then
		local TempDifference = ((ToLimbTemp/FromLimbTemp) - 1)/-1
		return {ToLimbDiff = TempDifference/ClampedArteriesResistance, FromLimbDiff = TempDifference/ClampedArteriesResistance * -1}
	end
	return {ToLimbDiff = 0, FromLimbDiff = 0}
end


-- Function used to return config stats.
local function FetchConfigStats()
	local ConfigStats = 
		{
		NormalBodyTemp = NTConfig.Get("NewNormalBodyTemp", 38),
		HypothermiaLevel = NTConfig.Get("NewHypothermiaLevel", 36),
		HyperthermiaLevel = NTConfig.Get("NewHyperthermiaLevel", 39),
		WarmingAbility = NTConfig.Get("NewWarmingAbility", .2),
		DryingSpeed = NTConfig.Get("NewDryingSpeed", -.1)
		}
	return ConfigStats
end


-- Function used to return random stats that I can't think of a better name for.
local function FetchOtherStats()
	local Stats =
	{
	AffectBodyCold = 1.1,
	AffectBodyWarm = 1.1,	
	LimbsToCheck = {LimbType.Head,LimbType.RightArm,LimbType.LeftArm,LimbType.LeftLeg,LimbType.RightLeg},
	BloodAfflictions = {"elevated_core_temperature","diuretics","thrombolytics","aafn"},
	MaxWarmingTemp = FetchConfigStats().NormalBodyTemp * 1.02,
	MaxCoolingTemp = FetchConfigStats().NormalBodyTemp/1.02
	}
	return Stats
end


-- Function used to transfer heat between limbs and torso.
local function TransferBodyHeat(character, TorsoTemp)
	local limbTemp = nil
	local TempDifference = nil
	local TotalTorsoTempDiff = 0
	-- Check to make sure that the temp isn't too low, else the torso will yoink temperature from nowhere. It shouldn't due to code I implemented in the ApplyHeatDifference func but this is still here as a failsafe.
	if not (TorsoTemp < 1.5) then
		for index, limb in pairs(FetchOtherStats().LimbsToCheck) do
			limbTemp = HF.GetAfflictionStrengthLimb(character, limb, "ntt_temperature", NTConfig.Get("NewNormalBodyTemp", 38))
			TempDifference = ApplyHeatDifference(character,limbTemp,limb,TorsoTemp,LimbType.Torso)
			TotalTorsoTempDiff = TotalTorsoTempDiff + TempDifference.FromLimbDiff
			HF.AddAfflictionLimb(character, "ntt_temperature", limb, TempDifference.ToLimbDiff, character)
		end
		return TotalTorsoTempDiff
	end 
	return 0 
end

-- Used for the passive temp increase from the environment.
local function GetRoomTempAddition(character,limb)
	local WetTemp = 0
	local WetStrength = HF.GetAfflictionStrengthLimb(character, limb, "wet", FetchConfigStats().NormalBodyTemp)
	local RoomTemp = 1
	if THERMRoom.GetRoom(character.CurrentHull) ~= nil then
		RoomTemp = THERMRoom.GetRoom(character.CurrentHull).Temp/THERMRoom.DefaultRoomTemp
	end
	if WetStrength > 0 then
		WetTemp = WetStrength/-1000
	end
	return (RoomTemp/10)
			+ WetTemp
end

-- Used to set arm swelling or leg swelling from a limb type.
local function LimbToSwelling(character,limb,duration)
	duration = duration or 2
	local Symptom = nil
	if HF.NormalizeLimbType(limb) == LimbType.LeftArm or HF.NormalizeLimbType(limb) == LimbType.RightArm then
		Symptom = "sym_armswelling"
	elseif HF.NormalizeLimbType(limb) == LimbType.LeftLeg or HF.NormalizeLimbType(limb) == LimbType.RightLeg then
		Symptom = "sym_legswelling"
	end
	if Symptom ~= nil then
		NTC.SetSymptomTrue(character, Symptom, duration)
	end
end


-- Used for a more varied blood clotting simulator.
local function CalculateBloodClots(character,limb,special)
	special = special or 0
	local BloodClottedLimbs = function ()
		local TotalClottedValue = 0
		for index, limb in pairs(Limbs) do
			if HF.GetAfflictionStrengthLimb(character, limb, "bloodclot", 0) > 0 then
				TotalClottedValue = TotalClottedValue + 1
			end
		end
		return TotalClottedValue
	end
	local TotalClots = BloodClottedLimbs()
	if HF.GetAfflictionStrengthLimb(character, limb, "bloodclot", 0) == 0 and math.random(TotalClots,4) > TotalClots + 1 then
		return .5
		* HF.GetAfflictionStrength(character, "bloodpressure", 100)
		/100 
		+ special * NT.Deltatime
	end
	return .25 * NT.Deltatime

end


-- Used to determine if a limb has been heated up too much. Basically make sure you're a good doctor. 
-- Note this is much different from thermal shock, as thermal shock is a body metric occuring every NT interval.
local function CalculateReperfusionInjury(degree, FrostBiteStrength, temp)
	local HypothermiaLevel = FetchConfigStats().HypothermiaLevel
	local DegreeMaxTemp = HypothermiaLevel
	if degree == "d1" then
		DegreeMaxTemp = HypothermiaLevel/NTTHERM.MediumHypothermiaScaling/1.6
	elseif degree == "d2" then
		DegreeMaxTemp = HypothermiaLevel/NTTHERM.ExtremeHypothermiaScaling/1.4
	elseif degree == "d3" then
		DegreeMaxTemp = 10
	end
	-- Formula to determine if the frostbite temp is too high given the temp it occurs at.
	if FrostBiteStrength/2/DegreeMaxTemp*(temp/DegreeMaxTemp) > 1.5 then
		return 25
	end
	return 0 
end


-- Used to determine if a limb will receive chilblains for a more varied experience.
local function CalculateChilblains(limb,character)
	local DefaultChance = 1
	local Chance = (HF.GetAfflictionStrengthLimb(character, limb, "wet", 0)/50)
	+ (HF.GetAfflictionStrength(character, "bloodpressure", 100)/100)
	+ DefaultChance
	if math.random(Chance,5) > Chance then
		return 25
	end
	return 0
end

-- Used to determine if the limb will heat cramp
local function CalculateHeatCramp(limb,character)
	local DefaultChance = 5
	local ElectrolyteGameplay = HF.GetAfflictionStrength(character, "afsaline", 100)/50
	if math.random(0,10) > DefaultChance + ElectrolyteGameplay then
		return 5
	end
	return 0
end

NTTHERM.UpdateLimbAfflictions = {

	--temperature
	ntt_temperature = {
		min = 1,
		max = 101,
		update = function(c, limbaff, i, type)
			if limbaff[i].strength > 0 then
				if THERM.GetCharacter(c.character.ID) ~= nil
					-- If the character is a bot with the safety suit config on, do not mess with temperature regardless of suit
					and not (NTConfig.Get("BotTempIgnoreMode", true) and c.character.IsBot) then
					local NormalBodyTemp = FetchConfigStats().NormalBodyTemp
					local HypothermiaLevel = FetchConfigStats().HypothermiaLevel
					local HyperthermiaLevel = FetchConfigStats().HyperthermiaLevel
					local AffectBodyCold = FetchOtherStats().AffectBodyCold
					local AffectBodyWarm = FetchOtherStats().AffectBodyWarm
					local TorsoTempStrength = HF.GetAfflictionStrengthLimb(c.character, LimbType.Torso, "ntt_temperature", 0)
					-- CompromisedTemp is the value at which the body will struggle to generate it's own heat or cool down. (You're cooked essentially.)
					local CompromisedColdTemp = HypothermiaLevel/1.5
					local CompromisedHotTemp = HyperthermiaLevel*1.5
					local CompromisedTempVal = 1
					-- Calculate new temperature
					limbaff[i].strength = limbaff[i].strength + THERM.CalculateTemperature(limbaff.wet.strength,c.character,type)
					-- Calculate CompromisedTempVal: Being too low or high in temperature will make the body slower to reach normal body temp.
					-- The division by three is a scaling feature, i'm too lazy to make it a variable.
					if limbaff[i].strength < CompromisedColdTemp then
						CompromisedTempVal = (CompromisedColdTemp/limbaff[i].strength)/3
					-- The division by five is a scaling feature as well, same as last one.
					elseif limbaff[i].strength > CompromisedHotTemp then
						CompromisedTempVal = (limbaff[i].strength/CompromisedHotTemp)/5
					end

						-- Make torso colder or warmer based off limb temp being lower then certain point.
					if type ~= LimbType.Torso then 
						-- Slight optimization, if the temps are the same don't calculate.
						if TorsoTempStrength ~= limbaff[i].strength then
							local TempDiffs = ApplyHeatDifference(c.character,TorsoTempStrength,LimbType.Torso,limbaff[i].strength,type)
							HF.AddAfflictionLimb(c.character, "ntt_temperature", LimbType.Torso, TempDiffs.ToLimbDiff, c.character)
							limbaff[i].strength = limbaff[i].strength + TempDiffs.FromLimbDiff
						end
						if type == LimbType.Head then
							if limbaff[i].strength < HypothermiaLevel and HF.GetAfflictionStrength(c.character, "husksymbiosis", 0) == 0 then
								HF.SetAffliction(c.character, "overlay_ice", HF.Clamp(5/limbaff[i].strength*150,0,60))
							elseif limbaff[i].strength > HyperthermiaLevel then
								HF.SetAffliction(c.character, "overlay_fire", HF.Clamp(limbaff[i].strength/NormalBodyTemp*50,0,100))
							else
								HF.SetAffliction(c.character, "overlay_ice", 0)
								HF.SetAffliction(c.character, "overlay_fire", 0)
							end
							if limbaff[i].strength < 2 and HF.GetAfflictionStrength(c.character, "husksymbiosis", 0) == 0 then
								c.afflictions.cerebralhypoxia.strength = c.afflictions.cerebralhypoxia.strength + (.05 * NT.Deltatime)
							elseif limbaff[i].strength < HypothermiaLevel/NTTHERM.ExtremeHypothermiaScaling/1.5 and HF.GetAfflictionStrength(c.character, "husksymbiosis", 0) == 0 then
								NTC.SetSymptomTrue(c.character, "sym_lightheadedness", 5)
							elseif limbaff[i].strength > HyperthermiaLevel * NTTHERM.MediumHyperthermiaScaling then
								NTC.SetSymptomTrue(c.character, "sym_fever", 5)
							end
						else
							--FrostNip
							if limbaff[i].strength < HypothermiaLevel/NTTHERM.MediumHypothermiaScaling 
								and limbaff.frostnip.strength == 0 
								and limbaff.d1_frostbite.strength == 0 
								and limbaff.d2_frostbite.strength == 0 
								and limbaff.d3_frostbite.strength == 0 
								and not THERM.IsLimbCyber(c.character,type) 
								and HF.GetAfflictionStrength(c.character, "husksymbiosis", 0) == 0 then
								limbaff.frostnip.strength = 1
							elseif  limbaff[i].strength > HyperthermiaLevel * NTTHERM.MediumHyperthermiaScaling then
								limbaff.heat_cramp.strength = limbaff.heat_cramp.strength + CalculateHeatCramp(type,c.character)
							end
						end
					else
						-- Give hypothermia
						if limbaff[i].strength < HypothermiaLevel and HF.GetAfflictionStrength(c.character, "husksymbiosis", 0) == 0 then
							c.afflictions.hypothermia.strength = 100
							if limbaff[i].strength < HypothermiaLevel * NTTHERM.ExtremeHypothermiaScaling then
							NTC.SetSymptomTrue(c.character, "dyspnea", 2)
							end
						-- Give hyperthermia
						elseif limbaff[i].strength > HyperthermiaLevel then
							c.afflictions.hyperthermia.strength = 100
							-- Get burnt nerd
							if limbaff[i].strength > HyperthermiaLevel * NTTHERM.ExtremeHyperthermiaScaling * 1.05 then
								limbaff.burn.strength = limbaff.burn.strength + (.5 * NT.Deltatime)
							elseif  limbaff[i].strength > HyperthermiaLevel * NTTHERM.ExtremeHyperthermiaScaling * 1.3 then
								limbaff.burn.strength = limbaff.burn.strength + (2 * NT.Deltatime)
							end
						end
						-- Transfer heat from body to rest of character for accurate gameplay provided by thou Rat Jaccuzi
						limbaff[i].strength = limbaff[i].strength + TransferBodyHeat(c.character,TorsoTempStrength)
					end

					-- Passive temperature reactions
					-- Warm up if cold.
					local RoomTempGain = GetRoomTempAddition(c.character,type)
					local AmputatedLimbValue = HF.BoolToNum(NT.LimbIsAmputated(c.character, type),1) + 1
					if limbaff[i].strength < NormalBodyTemp then
						limbaff[i].strength = HF.Clamp(limbaff[i].strength
							+ RoomTempGain + (.05
								/CompromisedTempVal
									*(c.afflictions.bloodpressure.strength
										/100)/AmputatedLimbValue
											* NT.Deltatime),1,NormalBodyTemp)
					-- Cool down if warm
					elseif limbaff[i].strength > NormalBodyTemp then
						limbaff[i].strength = HF.Clamp(limbaff[i].strength 
								- RoomTempGain - (.05
									/CompromisedTempVal
										*(c.afflictions.bloodpressure.strength
											/100)/AmputatedLimbValue 
											 * NT.Deltatime),NormalBodyTemp,101)
					end 
				end
				return
			-- Set Temperature since the current is 0.
			else
				limbaff[i].strength = FetchConfigStats().NormalBodyTemp
			end
		end,
	},

	--warmth
	warmth = {
		update = function(c, limbaff, i, type)
			local WarmingAbility = FetchConfigStats().WarmingAbility
			local WarmthScaling = 3
			local MaxWarmingTemp = FetchOtherStats().MaxWarmingTemp
			-- Warm up skin.
			if limbaff[i].strength > 0 then
				-- If the character is a bot with the temp ignore config on, don't change the temperature
				if not (NTConfig.Get("BotTempIgnoreMode", true) and c.character.IsBot) then
				limbaff.ntt_temperature.strength = limbaff.ntt_temperature.strength 
					+ (WarmingAbility
					/(limbaff.ntt_temperature.strength/MaxWarmingTemp)
					/WarmthScaling 
					* NT.Deltatime)
				end
				limbaff[i].strength = limbaff[i].strength - 1.7 * NT.Deltatime
				if type == LimbType.Torso and c.afflictions.internalbleeding.strength > 0 then
					c.afflictions.internalbleeding.strength = c.afflictions.internalbleeding.strength
						+ 0.2 * NT.Deltatime
				end
			end
		end,
	},

	--iced to lower temperature
	iced = {
		update = function(c, limbaff, i, type)
			local CoolingAbility = FetchConfigStats().WarmingAbility
			local MaxCoolingTemp = FetchOtherStats().MaxCoolingTemp
			local CoolScaling = -2.9
			-- over time skin temperature goes up again
			if limbaff[i].strength > 0 then
				limbaff[i].strength = limbaff[i].strength - 1.7 * NT.Deltatime
				-- If the character is a bot with the temp ignore config on, don't change the temperature
				if not (NTConfig.Get("BotTempIgnoreMode", true) and c.character.IsBot) then
				limbaff.ntt_temperature.strength = limbaff.ntt_temperature.strength 
					+ ((CoolingAbility
					/(MaxCoolingTemp/limbaff.ntt_temperature.strength))
					* CoolScaling  
					* NT.Deltatime)
				end
			end
			-- iced effects
			if limbaff[i].strength > 0 then
				c.stats.speedmultiplier = c.stats.speedmultiplier * 0.95 -- 5% slow per limb
				if type == LimbType.Torso then
					c.afflictions.internalbleeding.strength = c.afflictions.internalbleeding.strength
						- 0.2 * NT.Deltatime
				end
			end
		end,
	},

	--wet
	wet = {
		update = function(c, limbaff, i, type)
			-- cool down skin.
			if limbaff[i].strength > 0 then
				local DryingSpeed = FetchConfigStats().DryingSpeed
				local WetStrength = limbaff[i].strength
				local WetTempAddition = .1
				if limbaff.bandaged.strength > 0 then
					limbaff.dirtybandage.strength = limbaff.dirtybandage.strength + (WetStrength/4 * NT.Deltatime)
					limbaff.bandaged.strength = limbaff.bandaged.strength - (WetStrength/4 * NT.Deltatime)
				end
				limbaff.ntt_temperature.strength = limbaff.ntt_temperature.strength 
					+ (.05
						* (WetStrength + WetTempAddition) 
							* NT.Deltatime)
			end
		end,
	},

	--frostnip
	frostnip = {
		update = function(c, limbaff, i, type)
			if limbaff[i].strength > 0 and limbaff.d1_frostbite.strength == 0 and not THERM.IsLimbCyber(c.character,type) and HF.GetAfflictionStrength(c.character, "husksymbiosis", 0) == 0 then
				local LimbTemp = limbaff.ntt_temperature.strength
				local HypothermiaLevel = FetchConfigStats().HypothermiaLevel
				if LimbTemp < HypothermiaLevel/NTTHERM.MediumHypothermiaScaling then
					limbaff[i].strength = limbaff[i].strength + ((HypothermiaLevel/NTTHERM.MediumHypothermiaScaling/LimbTemp)* NT.Deltatime)
				else
					limbaff[i].strength = limbaff[i].strength - ((LimbTemp/HypothermiaLevel/NTTHERM.MediumHypothermiaScaling)* NT.Deltatime)
				end
				if limbaff[i].strength > 24.9  and LimbTemp < HypothermiaLevel/NTTHERM.ExtremeHypothermiaScaling then
					limbaff.d1_frostbite.strength = 1
				end
				return
			end
			limbaff[i].strength = 0
		end,
	},

	--1st degree frostbite
	d1_frostbite = {
		update = function(c, limbaff, i, type)
			if limbaff[i].strength > 0 and not THERM.IsLimbCyber(c.character,type) and HF.GetAfflictionStrength(c.character, "husksymbiosis", 0) == 0 then
				c.stats.speedmultiplier = c.stats.speedmultiplier * 0.90 -- 10% slow per limb
				NTC.SetSymptomTrue(c.character, "sym_pins_needles", 5)
				limbaff.frostnip.strength = 0
				local LimbTemp = limbaff.ntt_temperature.strength
				local HypothermiaLevel = FetchConfigStats().HypothermiaLevel
				if LimbTemp < HypothermiaLevel/NTTHERM.ExtremeHypothermiaScaling then
					limbaff[i].strength = limbaff[i].strength + ((HypothermiaLevel/NTTHERM.ExtremeHypothermiaScaling/LimbTemp)/2 * NT.Deltatime)
				else
					limbaff[i].strength = limbaff[i].strength - ((LimbTemp/HypothermiaLevel/NTTHERM.ExtremeHypothermiaScaling)* NT.Deltatime)
					if limbaff[i].strength < .1 then
						limbaff.frostnip.strength = 24.9
					end
				end
				if limbaff[i].strength > 24.9 and LimbTemp < HypothermiaLevel/NTTHERM.ExtremeHypothermiaScaling/1.5 then
					limbaff.d2_frostbite.strength = 1
				end
				limbaff.reperfusion_injury.strength = limbaff.reperfusion_injury.strength + CalculateReperfusionInjury("d1", limbaff[i].strength,HF.GetAfflictionStrengthLimb(c.character, type, "ntt_temperature", 0))
				return
			end
			limbaff[i].strength = 0
		end,
	},

	--2nd degree frostbite
	d2_frostbite = {
		update = function(c, limbaff, i, type)
			if limbaff[i].strength > 0 and not THERM.IsLimbCyber(c.character,type) and HF.GetAfflictionStrength(c.character, "husksymbiosis", 0) == 0 then
				c.stats.speedmultiplier = c.stats.speedmultiplier * 0.80 -- 20% slow per limb
				NTC.SetSymptomTrue(c.character, "sym_pins_needles", 5)
				limbaff.d1_frostbite.strength = 0
				local LimbTemp = limbaff.ntt_temperature.strength
				local HypothermiaLevel = FetchConfigStats().HypothermiaLevel
				limbaff.bloodclot.strength = limbaff.bloodclot.strength + (CalculateBloodClots(c.character,type) * NT.Deltatime)
				if LimbTemp < HypothermiaLevel/NTTHERM.ExtremeHypothermiaScaling/1.5 then
					limbaff[i].strength = limbaff[i].strength + ((HypothermiaLevel/NTTHERM.ExtremeHypothermiaScaling/1.5/LimbTemp)/2 * NT.Deltatime)
				else
					limbaff[i].strength = limbaff[i].strength - ((LimbTemp/HypothermiaLevel/NTTHERM.ExtremeHypothermiaScaling/1.1) * NT.Deltatime)
					if limbaff[i].strength < .1 then
						limbaff.d1_frostbite.strength = 24.9
						limbaff.chilblains.strength = limbaff.chilblains.strength + CalculateChilblains(type,c.character)
						limbaff.inflammation.strength = 10
						limbaff.pain_extremity.strength = 10
					end
				end
				if limbaff[i].strength > 24.9 and LimbTemp < 2 and not NT.LimbIsAmputated(c.character, type) then
					limbaff.d3_frostbite.strength = 1
				end
				limbaff.reperfusion_injury.strength = limbaff.reperfusion_injury.strength + CalculateReperfusionInjury("d2", limbaff[i].strength,HF.GetAfflictionStrengthLimb(c.character, type, "ntt_temperature", 0))
				return
			end
			limbaff[i].strength = 0
		end,
	},

	--3rd degree frostbite
	d3_frostbite = {
		update = function(c, limbaff, i, type)
			if limbaff[i].strength > 0 and not THERM.IsLimbCyber(c.character,type) and HF.GetAfflictionStrength(c.character, "husksymbiosis", 0) == 0 then
				c.stats.speedmultiplier = c.stats.speedmultiplier * 0.70 -- 30% slow per limb
				limbaff.d2_frostbite.strength = 0
				limbaff.bloodclot.strength = limbaff.bloodclot.strength + (CalculateBloodClots(c.character,type,.1) * NT.Deltatime)
				if limbaff.ntt_temperature.strength < 2 then
					limbaff[i].strength = limbaff[i].strength + (.5 * NT.Deltatime)
				end
				if limbaff[i].strength > 10 then
						if limbaff.gangrene.strength < 15 then
							limbaff.gangrene.strength = 15
						end
						limbaff.gangrene.strength = limbaff.gangrene.strength + (.1 * NT.Deltatime)
				else
					limbaff[i].strength = limbaff[i].strength - (.2 * NT.Deltatime)
					if limbaff[i].strength < .1 then
						limbaff.d2_frostbite.strength = 24.9
						limbaff.inflammation.strength = 10
					end
				end
				if NT.LimbIsAmputated(c.character, type) then
					limbaff.d3_frostbite.strength = 0
					limbaff.d2_frostbite.strength = 24.9
					limbaff.chilblains.strength = limbaff.chilblains.strength + CalculateChilblains(type,c.character)
					limbaff.pain_extremity.strength = 10
					limbaff.inflammation.strength = 10
				end
				limbaff.reperfusion_injury.strength = limbaff.reperfusion_injury.strength + CalculateReperfusionInjury("d3", limbaff[i].strength,HF.GetAfflictionStrengthLimb(c.character, type, "ntt_temperature", 0))
				return
			end
			limbaff[i].strength = 0
		end,
	},
	
	--Blood Clots
	bloodclot = {
		min = 0,
		max = 25,
		update = function(c, limbaff, i, type)
			if limbaff[i].strength > 0 then
				local BloodClotDissolvingRate = 0
				local BloodClotGrowthRate = 0
				local BloodPressureIncrease = 0
				local LimbClotScaling = 1
				if type == LimbType.LeftArm or type == LimbType.RightArm then
					LimbClotScaling = .4
				else
					LimbClotScaling = .2
				end
				if limbaff[i].strength < 16 then
					BloodClotDissolvingRate = .05
					BloodClotGrowthRate = .02
					BloodPressureIncrease = 1
				elseif limbaff[i].strength < 21 then
					LimbToSwelling(c.character,type,5)
					BloodClotDissolvingRate = .03
					BloodClotGrowthRate = .03
					BloodPressureIncrease = 2
					if math.random(0,5) > 4 and c.afflictions.lungremoved.strength == 0 then
						c.afflictions.pulmonary_embolism.strength = c.afflictions.pulmonary_embolism.strength + (.5 * NT.Deltatime)
					end
				elseif limbaff[i].strength > 21 then
					LimbToSwelling(c.character,type,5)
					BloodPressureIncrease = 3
					BloodClotGrowthRate = .04
					if c.afflictions.lungremoved.strength == 0 then
						c.afflictions.pulmonary_embolism.strength = c.afflictions.pulmonary_embolism.strength + (.5 * NT.Deltatime)
					end
				end
				c.afflictions.bloodpressure.strength = c.afflictions.bloodpressure.strength + (BloodPressureIncrease * NT.Deltatime)
				limbaff[i].strength = limbaff[i].strength 
					- ((BloodClotDissolvingRate 
						* (c.afflictions.thrombolytics.strength/10)
							- c.afflictions.acidosis.strength/1000
								+ c.afflictions.alkalosis.strength/1000
									+ c.afflictions.bloodpressure.strength/1000
										+ 1 * LimbClotScaling) 
											+ BloodClotGrowthRate * NT.Deltatime)
			end
		end,
	},

	-- Blister type rab lat stuff. I just noticed I mis-typed that around 5 days later, we're balling with it tho.
	chilblains = {
		update = function(c, limbaff, i, type)
			if limbaff[i].strength > 0 then
				local PassiveDecay = .05
				local HyperthermiaLevel = FetchConfigStats().HyperthermiaLevel
				limbaff[i].strength = limbaff[i].strength - ((PassiveDecay
					+ limbaff.bandaged.strength/500 
						* HF.Clamp(limbaff.ointmented.strength/50,1,2))
							* HF.Clamp(limbaff.warmth.strength/50,1,2)
								* NT.Deltatime)
				if limbaff.ntt_temperature.strength > HyperthermiaLevel then
					limbaff.infectedwound.strength = limbaff.infectedwound.strength + (.05 * NT.Deltatime)
				end
				if limbaff.bandaged.strength < 1 then
					limbaff.infectedwound.strength = limbaff.infectedwound.strength + ((limbaff.wet.strength/100) + math.random(.5,1) * NT.Deltatime)
				end
			end
		end,
	},

	-- Reperfusion Injury.
	reperfusion_injury = {
		update = function(c, limbaff, i, type)
			if limbaff[i].strength > 0 then
				local InternalDamageRate = .05
				local BoneDamage = .1
				local PassiveHeal = .1
				limbaff.internaldamage.strength = limbaff.internaldamage.strength + (InternalDamageRate * NT.Deltatime)
				c.afflictions.bonedamage.strength = c.afflictions.bonedamage.strength + (BoneDamage * NT.Deltatime)
				limbaff[i].strength = limbaff[i].strength - PassiveHeal
			end
		end,
	},

	-- Heat Cramp
	heat_cramp = {
		max = 25,
		update = function(c, limbaff, i, type)
			if limbaff[i].strength > 0 then
				local HyperthermiaLevel = FetchConfigStats().HyperthermiaLevel
				HF.AddAfflictionLimb(c.character, "spasm", type, 10)
				limbaff[i].strength = limbaff[i].strength 
										- (.5 -- Go down 1 percent each tick.
										- (c.afflictions.afsaline.strength/50)
										* NT.Deltatime)
				if limbaff.ntt_temperature.strength < HyperthermiaLevel * NTTHERM.MediumHyperthermiaScaling then
					limbaff[i].strength = 0
				end
			end
		end,
	},
}

NTTHERM.UpdateAfflictions = {

	-- Pulmonary Embolism
	pulmonary_embolism = {
		max = 100,
		update = function(c, i)
			if c.afflictions[i].strength > 0 then
				if c.afflictions.lungremoved.strength > 0 then
						if c.afflictions.lungdamage.strength >= 50 then
							c.afflictions.internalbleeding.strength = 50
						end
						c.afflictions[i].strength = 0
					end
				if c.afflictions[i].strength > 10 then
					NTC.SetSymptomTrue(c.character, "dyspnea", 5)
				end
				if c.afflictions[i].strength > 25 then
					NTC.SetSymptomTrue(c.character, "pain_chest", 5)
				end
				if c.afflictions[i].strength > 75 then
					NTC.SetSymptomTrue(c.character, "triggersym_respiratoryarrest", 2)
				end
				c.afflictions[i].strength = c.afflictions[i].strength 
					- (c.afflictions.thrombolytics.strength/3.5 
					- c.afflictions.afstreptokinase.strength/10 
					- .2 
					* NT.Deltatime)
			end
		end,
	},

	-- Pulmonary Edema
		pulmonary_edema = {
			max = 100,
			update = function(c, i)
				if c.afflictions[i].strength > 0 then
					if c.afflictions.lungremoved.strength > 0 then
						if c.afflictions.lungdamage.strength >= 50 then
							c.afflictions.internalbleeding.strength = 50
						end
						c.afflictions[i].strength = 0
					end
					c.afflictions[i].strength = c.afflictions[i].strength 
						+ (c.afflictions.heartdamage.strength/80 -- Heart Damage aids Edema
						+ c.afflictions.bloodpressure.strength/50 -- High blood pressure aids in edema
						+ c.afflictions.sepsis.strength/50 -- Sepsis still isn't chill
						+ THERM.GetCharacter(c.character.ID).LimbWaterValues.TorsoV/50 -- Swimming induced pulmonary edema.
						- c.afflictions.diuretics.strength/10 -- Treatment
						* NT.Deltatime) -- Delta gameplay
						NTC.SetSymptomTrue(c.character, "dyspnea", 5)
						if c.afflictions[i].strength > 25 then
							NTC.SetSymptomTrue(c.character, "sym_wheezing", 5)
							if c.afflictions[i].strength > 70 then
								NTC.SetSymptomTrue(c.character, "sym_hematemesis", 5)
								NTC.SetSymptomTrue(c.character, "triggersym_respiratoryarrest", 2)
							end
						end
				elseif c.afflictions.heartdamage.strength > 80 and c.afflictions.heartremoved.strength == 0 then
					c.afflictions[i].strength = 1
				end
			end,
		},

	--Hypothermia 
	hypothermia = {
		max = 100,
		update = function(c, i)
			if c.afflictions[i].strength > 0 and HF.GetAfflictionStrength(c.character, "husksymbiosis", 0) == 0 then
				local HypothermiaLevel = FetchConfigStats().HypothermiaLevel
				local NormalBodyTemp = FetchConfigStats().NormalBodyTemp
				local TorsoTemp = HF.GetAfflictionStrength(c.character, "ntt_temperature", 0)
				c.afflictions.bloodpressure.strength = c.afflictions.bloodpressure.strength + (.2 * NT.Deltatime)
				if TorsoTemp < 2 then
					c.afflictions.frozen_vessels.strength = c.afflictions.frozen_vessels.strength + (2 * NT.Deltatime)
					NTC.SetSymptomTrue(c.character, "triggersym_coma", 2)
				end
				if TorsoTemp < HypothermiaLevel/NTTHERM.ExtremeHypothermiaScaling/2 then
					NTC.SetSymptomTrue(c.character, "triggersym_respiratoryarrest", 2)
					c.afflictions.analgesia.strength = c.afflictions.analgesia.strength + (.5 * NT.Deltatime)
					c.afflictions.immunity.strength = c.afflictions.immunity.strength - (5 * NT.Deltatime)
				end
				if TorsoTemp < HypothermiaLevel/NTTHERM.ExtremeHypothermiaScaling/1.5 then
					c.afflictions.bloodpressure.strength = c.afflictions.bloodpressure.strength + (.1 * NT.Deltatime)
					c.afflictions.pulmonary_edema.strength = c.afflictions.pulmonary_edema.strength 
						+ (THERM.GetCharacter(c.character.ID).LimbWaterValues.TorsoV/50 
						* c.afflictions.lungdamage.strength/50
						* NT.Deltatime)
					NTC.SetSymptomTrue(c.character, "sym_paleskin", 5)
					NTC.SetSymptomTrue(c.character, "sym_unconsciousness", 2)

				end
				if TorsoTemp < HypothermiaLevel/NTTHERM.ExtremeHypothermiaScaling then
					c.afflictions.bloodpressure.strength = c.afflictions.bloodpressure.strength + (.05 * NT.Deltatime)
					NTC.SetSymptomTrue(c.character, "hypoventilation", 2)
				end
				if  HF.GetAfflictionStrength(c.character, "ntt_temperature", 0) > HypothermiaLevel then
					c.afflictions.hypothermia.strength = 0
				end
			else
				c.afflictions.hypothermia.strength = 0
			end
		end,
	},

	--Hyperthermia
	hyperthermia = {
		max = 100,
		update = function(c, i)
			if c.afflictions[i].strength > 0 then
				local Death = (5 * NT.Deltatime)
				local HyperthermiaLevel = FetchConfigStats().HyperthermiaLevel
				local NormalBodyTemp = FetchConfigStats().NormalBodyTemp
				local TorsoTemp = HF.GetAfflictionStrength(c.character, "ntt_temperature", 0)
				c.afflictions.bloodpressure.strength = c.afflictions.bloodpressure.strength - (.2 * NT.Deltatime)
				if TorsoTemp < HyperthermiaLevel then
					c.afflictions.hyperthermia.strength = 0
					return
				end
				if TorsoTemp > HyperthermiaLevel and TorsoTemp < HyperthermiaLevel * NTTHERM.ExtremeHyperthermiaScaling * 1.05 then
					NTC.SetSymptomTrue(c.character, "sym_sweating", 2)
				end
				if TorsoTemp > HyperthermiaLevel * NTTHERM.ExtremeHyperthermiaScaling then
					NTC.SetSymptomTrue(c.character, "sym_headache", 2)
				end
				if TorsoTemp > HyperthermiaLevel * NTTHERM.ExtremeHyperthermiaScaling * 1.05 then
					c.afflictions.heat_stroke.strength = c.afflictions.heat_stroke.strength + (1 * NT.Deltatime)
					HF.AddAffliction(c.character, "huskinfection", -10 * NT.Deltatime, c.character) -- EXTERMINATE THE BITCH ASS HUSK. JUSTICE FOR ARTIE DOOLITTLE. THOSE BASTARDS SLIMED HIM OUT. God speed artie, love you.
					-- NT Symbiote compat:
					if HF.HasAffliction(c.character, "surgery_huskhealth", 1) then
						HF.AddAffliction(c.character, "surgery_huskhealth", -10 * NT.Deltatime, c.character)
					end
				end
				if TorsoTemp > HyperthermiaLevel * NTTHERM.ExtremeHyperthermiaScaling * 1.2 then
					c.afflictions.cerebralhypoxia.strength = c.afflictions.cerebralhypoxia.strength + Death
					c.afflictions.lungdamage.strength = c.afflictions.lungdamage.strength + Death
					c.afflictions.liverdamage.strength = c.afflictions.liverdamage.strength + Death
					c.afflictions.heartdamage.strength = c.afflictions.heartdamage.strength + Death
					c.afflictions.kidneydamage.strength = c.afflictions.kidneydamage.strength + Death
				end
			end
		end,
	},

	-- FrozenVessels
	frozen_vessels = {
		update = function(c, i)
			if c.afflictions[i].strength > 0 then
				local PassiveDecay = .2
				local CellDeathGrowth = .2
				local BodyTemp = HF.GetAfflictionStrength(c.character, "ntt_temperature", 0)
				local HypothermiaLevel = FetchConfigStats().HypothermiaLevel
				if c.afflictions[i].strength < 10 then
					c.afflictions[i].strength = c.afflictions[i].strength - (PassiveDecay * NT.Deltatime)
				end
				if BodyTemp > HypothermiaLevel/NTTHERM.ExtremeHypothermiaScaling/4.5 then
					local Formula = ((CellDeathGrowth + BodyTemp/10)  * NT.Deltatime)
					c.afflictions.cell_death.strength = c.afflictions.cell_death.strength + Formula
					c.afflictions[i].strength = c.afflictions[i].strength - Formula
				end
				-- aafn clutch.
				c.afflictions[i].strength = c.afflictions[i].strength - (c.afflictions.aafn.strength/20 * NT.Deltatime)
			end
		end,
	},

	-- Cell Death (Clots and prayers)
	cell_death = {
		update = function(c, i)
			if c.afflictions[i].strength > 0 then
				local InternalBleedingIncrease = .2
				local LiverDamageIncrease = 1
				local Death = (1 * NT.Deltatime)
				c.afflictions.internalbleeding.strength = c.afflictions.internalbleeding.strength + (InternalBleedingIncrease * NT.Deltatime)
				if c.afflictions[i].strength < 5 then
					NTC.SetSymptomTrue(c.character, "sym_confusion", 5)
					-- It does slowly go down.
					c.afflictions[i].strength = c.afflictions[i].strength - (.01 * NT.Deltatime)
				end
				if c.afflictions[i].strength > 5 then
					NTC.SetSymptomTrue(c.character, "sym_nausea", 5)
					c.afflictions.cerebralhypoxia.strength = c.afflictions.cerebralhypoxia.strength + Death
					c.afflictions.lungdamage.strength = c.afflictions.lungdamage.strength + Death
					c.afflictions.liverdamage.strength = c.afflictions.liverdamage.strength + Death
					c.afflictions.heartdamage.strength = c.afflictions.heartdamage.strength + Death
					c.afflictions.kidneydamage.strength = c.afflictions.kidneydamage.strength + Death
				end
				if c.afflictions[i].strength > 30 then
					c.afflictions.internalbleeding.strength = c.afflictions.internalbleeding.strength + (InternalBleedingIncrease * 2 * NT.Deltatime)
					NTC.SetSymptomTrue(c.character, "triggersym_stroke", 5)
				end
			end
		end,
	},

	--Give temperature affliction, this is used to hook water and fire related stuff to the player for temperature.
	-- Those aren't stored in here since they have a independent tick rate.
	givetemp = {
		max = 3,
		update = function(c, i)
			if c.afflictions[i].strength > 0 then
				return
			else
				THERM.IntiateCharacterTemp(c.character)
				THERM.ValidateThermalCharacterData()
				c.afflictions[i].strength = 3
			end
		end,
	},

	-- Rip
	aafn_overdose = {
		max = 100,
		update = function(c, i)
			if c.afflictions[i].strength > 0 then
				local Death = (5 * NT.Deltatime)
				if c.afflictions.aafn.strength > 0 then
					c.afflictions[i].strength = c.afflictions[i].strength + Death
				else
					c.afflictions[i].strength = c.afflictions[i].strength + (Death * -1)
				end
				c.afflictions.cerebralhypoxia.strength = c.afflictions.cerebralhypoxia.strength + Death
				c.afflictions.lungdamage.strength = c.afflictions.lungdamage.strength + Death
				c.afflictions.liverdamage.strength = c.afflictions.liverdamage.strength + Death
				c.afflictions.heartdamage.strength = c.afflictions.heartdamage.strength + Death
				c.afflictions.kidneydamage.strength = c.afflictions.kidneydamage.strength + Death
				c.afflictions.seizure.strength = c.afflictions.seizure.strength + (10 * NT.Deltatime)
			end
		end,
	},

	-- Thermal Shock
	thermal_shock = {
		max = 100,
		update = function(c, i)
			local TorsoTemp = HF.GetAfflictionStrengthLimb(c.character, LimbType.Torso, "ntt_temperature", 0)
			local LastTorsoTemp = 0
			local NormalBodyTemp = FetchConfigStats().NormalBodyTemp
			if THERM.GetCharacter(c.character.ID) ~= nil then
				LastTorsoTemp = THERM.GetCharacter(c.character.ID).LastStoredTorsoTemp
			end
			if LastTorsoTemp == 0 then
				LastTorsoTemp = TorsoTemp
			end
			local ShockMargin = .28 * NT.Deltatime
			local ShockDecrease = 2.5
			if c.afflictions[i].strength > 0 then
				NTC.SetSymptomTrue(c.character, "triggersym_seizure", 5)
				NTC.SetSymptomTrue(c.character, "triggersym_stroke", 5)
				c.afflictions.cerebralhypoxia.strength = c.afflictions.cerebralhypoxia.strength + (.05 * NT.Deltatime)
				c.afflictions[i].strength = c.afflictions[i].strength -  (ShockDecrease * NT.Deltatime)
			elseif LastTorsoTemp ~= TorsoTemp then
				if    TorsoTemp/LastTorsoTemp/2 > ShockMargin -- Too hot
				   or LastTorsoTemp/TorsoTemp/2 > ShockMargin -- Too cold
				then
					if (TorsoTemp < NormalBodyTemp and LastTorsoTemp > NormalBodyTemp)
						or (TorsoTemp > NormalBodyTemp and LastTorsoTemp < NormalBodyTemp)
						then
						c.afflictions[i].strength = 100
					end
				end
			end
		end,
	},

	-- Heat Stroke
	heat_stroke = {
		max = 100,
		update = function(c, i)
			if c.afflictions[i].strength > 0 then
				local TorsoTemp = HF.GetAfflictionStrength(c.character, "ntt_temperature", 0)
				local HyperthermiaLevel = FetchConfigStats().HyperthermiaLevel
				NTC.SetSymptomTrue(c.character, "triggersym_seizure", 2)
				NTC.SetSymptomTrue(c.character, "sym_blurredvision", 2)
				NTC.SetSymptomTrue(c.character, "sym_confusion", 2)
				if c.afflictions[i].strength > 50 then
					NTC.SetSymptomTrue(c.character, "triggersym_heartattack", 2)
				end
				if c.afflictions[i].strength > 75 then
					c.afflictions.cerebralhypoxia.strength = c.afflictions.cerebralhypoxia.strength + (.1 * NT.Deltatime)
				end
				if TorsoTemp < HyperthermiaLevel * NTTHERM.ExtremeHyperthermiaScaling * 1.05 then
					c.afflictions[i].strength = 0
				end
			end
		end,
	},

	-- Heated Diving Suit
	heated_diving_suit = {
		max = 100,
		update = function(c, i)
			-- Used for suits that have automatic heating or prebuilt power. I'm too scared to refactor this.
			local ExceptedSuits = {["respawndivingsuit"] = {valid = true,index = 0},["exosuit"] = {valid = true, index =1},["clownexosuit"] = {valid = true, index = 1}, --Vanilla Ice Cream
			["SAFS"] = {valid = true, index = 1},["SAFS_V7"] = {valid = true, index = 1},["SAFS_nāga"] = {valid = true, index = 1},["SAFS_snow"] = {valid = true, index = 1},["SAFS_yellow"] = {valid = true, index = 1},  -- Safs compatibility
			["SAFS_manual"] = {valid = true, index = 1},["SAFS_seaweed"] = {valid = true, index = 1},["SAFS_clown"] = {valid = true, index = 1},["SAFS_camo"] = {valid = true, index = 1},["SAFS_moon"] = {valid = true, index = 1},  -- Safs compatibility
			["SAFS_onyx"] = {valid = true, index = 1},["SAFS_camo2"] = {valid = true, index = 1},  -- Safs compatibility
			["ek_armored_hardsuit"] = {valid = true, index = 1},["ek_armored_hardsuit_paintbandit"] = {valid = true, index = 1},["ek_armored_hardsuit_paintmercenary"] = {valid = true, index = 1},["ek_armored_hardsuit2"] = {valid = true, index = 1} -- EK
			,["ek_armored_hardsuit2_paintbandit"] = {valid = true, index = 1},["ek_armored_hardsuit2_paintmercenary"] = {valid = true, index = 1}, -- EK
			['exosuitplayerPA'] = {valid = true, index = 1},['exosuitPA'] = {valid = true, index = 1},["piratedivingsuitmakeshift"] = {valid = true,index = 0}, -- Dynamic Europa
			['scp_combathardsuit'] = {valid = true, index = 1}} -- EA
			local IndexedSuits = {["pucs"] = 2} -- Used for suits that have extra storage. I.E pucs.
			local HypothermiaLevel = FetchConfigStats().HypothermiaLevel
			if c.afflictions[i].strength > 0 then
				local CharacterTable = THERM.GetCharacter(c.character.ID,c.character)
				local LimbsToCheck2 = {LimbType.Head,LimbType.Torso,LimbType.RightArm,LimbType.LeftArm,LimbType.LeftLeg,LimbType.RightLeg}
				for index, limb in pairs(LimbsToCheck2) do
					local LimbTemp = HF.GetAfflictionStrengthLimb(c.character, limb, "ntt_temperature", 0)
					if LimbTemp < FetchConfigStats().NormalBodyTemp then
						local WaterKey = THERM.LimbToWaterLimbV(limb)
						local WaterCounter = HF.Clamp(CharacterTable.LimbWaterValues[WaterKey]/1,.1,1)
						local IsCyber = HF.BoolToNum(THERM.IsLimbCyber(c.character,limb),1) + 1
						HF.AddAfflictionLimb(c.character, "ntt_temperature", limb, 
											(HypothermiaLevel/LimbTemp
											/25) 
											* (c.afflictions[i].strength
											/100) 
											* 20
											* IsCyber
											* WaterCounter 
											* NT.Deltatime)
					end
				end
			end
			local DivingSuit = c.character.Inventory.GetItemInLimbSlot(InvSlotType.OuterClothes)
			local Bag = c.character.Inventory.GetItemInLimbSlot(InvSlotType.Bag)
			local BatteryConsumption = NTConfig.Get("HeaterBatteryConsumption") * NT.Deltatime
			if c.character.Inventory.GetItemInLimbSlot(InvSlotType.OuterClothes) ~= nil and (c.character.Inventory.GetItemInLimbSlot(InvSlotType.OuterClothes).HasTag("diving") or c.character.Inventory.GetItemInLimbSlot(InvSlotType.OuterClothes).HasTag("deepdivinglarge") or c.character.Inventory.GetItemInLimbSlot(InvSlotType.OuterClothes).HasTag("deepdiving")) then
				-- Internal Heater Check
				local Index = IndexedSuits[tostring(DivingSuit.Prefab.Identifier)] or IndexedSuits[tostring(DivingSuit.Prefab.VariantOf)] or 1
				-- Suit Compatibility Mode is on
				if NTConfig.Get("SuitCompatiblityMode", false) or (NTConfig.Get("BotSuitSafteyMode", true) and c.character.IsBot)then
					c.afflictions[i].strength = c.afflictions[i].strength + (5 * NT.Deltatime)
					return

				elseif (DivingSuit.HasTag("thermal") or (Index ~= 1 and DivingSuit.Prefab.VariantOf ~= "" and DivingSuit.Prefab.VariantOf.HasTag("thermal"))) and DivingSuit.OwnInventory.GetItemAt(Index) ~= nil and DivingSuit.OwnInventory.GetItemAt(Index).Condition > 1 then
					local BatteryCell = c.character.Inventory.GetItemInLimbSlot(InvSlotType.OuterClothes).OwnInventory.GetItemAt(Index)
					if BatteryCell.Condition > 1 then
						BatteryCell.Condition = BatteryCell.Condition - BatteryConsumption
						c.afflictions[i].strength = c.afflictions[i].strength + (5 * NT.Deltatime)
						return
					end
					c.afflictions[i].strength = 0
					return

				-- External Heater Check
				elseif Bag ~= nil and Bag.Prefab.Identifier == "esh" and Bag.OwnInventory.GetItemAt(0) ~= nil and Bag.OwnInventory.GetItemAt(0).Condition > 1 then
					local BatteryCell = Bag.OwnInventory.GetItemAt(0)
					if BatteryCell ~= nil and BatteryCell.Condition > 1 then
						BatteryCell.Condition = BatteryCell.Condition - BatteryConsumption
						c.afflictions[i].strength = c.afflictions[i].strength + (5 * NT.Deltatime)
						return
					end
					c.afflictions[i].strength = 0
					return

				-- ExceptedSuits
				elseif ExceptedSuits[tostring(DivingSuit.Prefab.Identifier)] ~= nil then
					local HeaterIndex = ExceptedSuits[tostring(DivingSuit.Prefab.Identifier)].index
					if HeaterIndex ~= 0 
						and DivingSuit.OwnInventory.GetItemAt(HeaterIndex) 
						and DivingSuit.OwnInventory.GetItemAt(HeaterIndex).Condition > 1 then
						c.afflictions[i].strength = c.afflictions[i].strength + (5 * NT.Deltatime)
						return
					elseif HeaterIndex == 0 then
						c.afflictions[i].strength = c.afflictions[i].strength + (5 * NT.Deltatime)
						return
					end
					c.afflictions[i].strength = 0
					return
				end
				c.afflictions[i].strength = 0
				return

			-- Immersive Diving Gear compat (Yes this is basically duplicated code, you're welcome.)
			elseif c.character.Inventory.GetItemInLimbSlot(InvSlotType.OuterClothes) ~= nil
			 	and THERM.ImmersiveDivingGearEquipped(c.character.Inventory.GetItemInLimbSlot(InvSlotType.OuterClothes),c.character.Inventory.GetItemInLimbSlot(InvSlotType.InnerClothes)) then
				if NTConfig.Get("SuitCompatiblityMode", false) or (NTConfig.Get("BotSuitSafteyMode", true) and c.character.IsBot) then
					c.afflictions[i].strength = c.afflictions[i].strength + (5 * NT.Deltatime)
					return
				elseif DivingSuit.OwnInventory ~= nil and DivingSuit.OwnInventory.GetItemAt(0) ~= nil and DivingSuit.OwnInventory.GetItemAt(0).Condition > 1 then
					local BatteryCell = DivingSuit.OwnInventory.GetItemAt(0)
					BatteryCell.Condition = BatteryCell.Condition - BatteryConsumption
					c.afflictions[i].strength = c.afflictions[i].strength + (5 * NT.Deltatime)
					return
				elseif Bag ~= nil and Bag.Prefab.Identifier == "esh" and Bag.OwnInventory.GetItemAt(0) ~= nil and Bag.OwnInventory.GetItemAt(0).Condition > 1 then
					local BatteryCell = Bag.OwnInventory.GetItemAt(0)
					if BatteryCell ~= nil and BatteryCell.Condition > 1 then
						BatteryCell.Condition = BatteryCell.Condition - BatteryConsumption
						c.afflictions[i].strength = c.afflictions[i].strength + (5 * NT.Deltatime)
						return
					end
					c.afflictions[i].strength = 0
					return
				end
				c.afflictions[i].strength = 0
			end
			c.afflictions[i].strength = 0
		end,
	},

	-- Symptoms -----------------------------------------------
	-- Cold
	sym_cold = {
		update = function(c, i)
			c.afflictions[i].strength = HF.BoolToNum(
					not NTC.GetSymptomFalse(c.character, i)
					and (NTC.GetSymptom(c.character, i)
					or HF.GetAfflictionStrength(c.character, "hypothermia", 0) > 0)
					and HF.GetAfflictionStrength(c.character, "husksymbiosis", 0) == 0,
				2
			)
		end,
	},

	-- Shivers
	sym_shivers = {
		update = function(c, i)
			local HypothermiaLevel = FetchConfigStats().HypothermiaLevel
			c.afflictions[i].strength = HF.BoolToNum(
				not NTC.GetSymptomFalse(c.character, i)
					and (NTC.GetSymptom(c.character, i)
					or (HF.GetAfflictionStrength(c.character, "ntt_temperature", 0) < HypothermiaLevel/NTTHERM.MediumHypothermiaScaling 
					and HF.GetAfflictionStrength(c.character, "ntt_temperature", 0) > HypothermiaLevel/NTTHERM.ExtremeHypothermiaScaling))
					and HF.GetAfflictionStrength(c.character, "husksymbiosis", 0) == 0,
				2
			)
		end,
	},

	-- Numb
	sym_numb = {
		update = function(c, i)
			local HypothermiaLevel = FetchConfigStats().HypothermiaLevel
			c.afflictions[i].strength = HF.BoolToNum(
				not NTC.GetSymptomFalse(c.character, i)
					and (NTC.GetSymptom(c.character, i)
					or HF.GetAfflictionStrength(c.character, "ntt_temperature", 0) < HypothermiaLevel/NTTHERM.ExtremeHypothermiaScaling
					and HF.GetAfflictionStrength(c.character, "ntt_temperature", 0) > 0)
					and HF.GetAfflictionStrength(c.character, "husksymbiosis", 0) == 0,
				2
			)
		end,
	},

	-- Runny Nose
	sym_runny_nose = {
		update = function(c, i)
			local HypothermiaLevel = FetchConfigStats().HypothermiaLevel
			c.afflictions[i].strength = HF.BoolToNum(
				not NTC.GetSymptomFalse(c.character, i)
					and (NTC.GetSymptom(c.character, i)
					or (HF.GetAfflictionStrengthLimb(c.character, LimbType.Head, "ntt_temperature", NTConfig.Get("NormalBodyTemp", 38)) < HypothermiaLevel 
					and HF.GetAfflictionStrengthLimb(c.character, LimbType.Head, "ntt_temperature", NTConfig.Get("NormalBodyTemp", 38)) > HypothermiaLevel/NTTHERM.ExtremeHypothermiaScaling/1.5))
					and HF.GetAfflictionStrength(c.character, "husksymbiosis", 0) == 0,
				2
			)
		end,
	},

	-- Hot
	sym_hot = {
		update = function(c, i)
			local HyperthermiaLevel = FetchConfigStats().HyperthermiaLevel
			c.afflictions[i].strength = HF.BoolToNum(
				not NTC.GetSymptomFalse(c.character, i)
					and (NTC.GetSymptom(c.character, i)
					or HF.GetAfflictionStrength(c.character, "ntt_temperature", NTConfig.Get("NormalBodyTemp", 38)) > HyperthermiaLevel * NTTHERM.MediumHyperthermiaScaling),
				2
			)
		end,
	},

	-- Arm Swelling
	sym_armswelling = {
		update = function(c, i)
			c.afflictions[i].strength = HF.BoolToNum(
				not NTC.GetSymptomFalse(c.character, i)
					and NTC.GetSymptom(c.character, i),
				2
			)
		end,
	},

	-- Pins and Needles
	sym_pins_needles = {
		update = function(c, i)
			c.afflictions[i].strength = HF.BoolToNum(
				not NTC.GetSymptomFalse(c.character, i)
					and NTC.GetSymptom(c.character, i),
				2
			)
		end,
	},

}


-- Afflictions used for blood related stuff.
NTTHERM.UpdateBloodAfflictions = {

	-- Elevated Core Temp
	elevated_core_temperature = {
		max = 50,
		update = function (c, i)
			local NormalBodyTemp = FetchConfigStats().NormalBodyTemp
			local MaxWarmingTemp = FetchOtherStats().MaxWarmingTemp
			local LimbStrength = HF.GetAfflictionStrength(c.character, "ntt_temperature", NormalBodyTemp)
			local BloodPressureMultiplier = 3
			local ElevationDecrease = .1
			local TempIncrease = .1
			if c.afflictions[i].strength > 0 then
				for index, limb in pairs(FetchOtherStats().LimbsToCheck) do
					local Chilled = HF.Clamp(HF.GetAfflictionStrengthLimb(c.character, limb, "iced", 1)/50,1,2)
					-- If the character is a bot with the temp ignore config on, don't change the temperature
					if not (NTConfig.Get("BotTempIgnoreMode", true) and c.character.IsBot) then
					HF.AddAfflictionLimb(c.character, "ntt_temperature", limb, 
						TempIncrease
						+ (MaxWarmingTemp/LimbStrength)/80 
						* c.afflictions[i].strength/20 
						/ Chilled
						* NT.Deltatime)
					end
				end
				-- Side effect of elevated_core_temperature.
				if c.afflictions[i].strength > 30 then
					c.afflictions.bloodpressure.strength = c.afflictions.bloodpressure.strength 
					+ (c.afflictions[i].strength/15 * BloodPressureMultiplier * NT.Deltatime)
					NTC.SetSymptomTrue(c.character, "sym_lightheadedness", 5)
				end
				if c.afflictions[i].strength > 40 then
					NTC.SetSymptomTrue(c.character, "sym_confusion", 3)
					c.afflictions.seizure.strength = c.afflictions.seizure.strength 
					+ (10 * NT.Deltatime)
					c.afflictions.organdamage.strength =  c.afflictions.organdamage.strength + 
					(.5 * NT.Deltatime)
				end
				c.afflictions[i].strength = c.afflictions[i].strength - (ElevationDecrease * NT.Deltatime)
			end
		end
	},

	thrombolytics = {
		update = function (c, i)
			if c.afflictions[i].strength > 0 then
				c.afflictions.bloodpressure.strength = c.afflictions.bloodpressure.strength - (c.afflictions[i].strength/800 * NT.Deltatime)
				c.afflictions.kidneydamage.strength = c.afflictions.kidneydamage.strength + (c.afflictions[i].strength/10000 * NT.Deltatime)
				c.afflictions[i].strength = c.afflictions[i].strength - (.25 * NT.Deltatime)
			end
		end
	},

	diuretics = {
		update = function (c, i)
			if c.afflictions[i].strength > 0 then
				local BloodPressureDecrease = .05
				c.afflictions.bloodpressure.strength = c.afflictions.bloodpressure.strength - (BloodPressureDecrease * NT.Deltatime)
				NTC.SetSymptomTrue(c.character, "sym_headache", 3)
				c.afflictions[i].strength = c.afflictions[i].strength - (.25 * NT.Deltatime)
				if c.afflictions[i].strength > 50 then
					NTC.SetSymptomTrue(c.character, "sym_bloating", 5)
				end
			end
		end
	},

	aafn = {
		update = function (c, i)
			if c.afflictions[i].strength > 0 then
				local AntiFreezeAbility = .2
				c.afflictions.heartdamage.strength = c.afflictions.heartdamage.strength + (.1 *NT.Deltatime)
				c.afflictions[i].strength = c.afflictions[i].strength - (AntiFreezeAbility * NT.Deltatime)
				NTC.SetSymptomTrue(c.character, "sym_bloating", 5)
				if c.afflictions[i].strength > 25 then
					c.afflictions.internalbleeding.strength = c.afflictions.internalbleeding.strength + (.1 * NT.Deltatime)
					NTC.SetSymptomTrue(c.character, "sym_hematemesis", 5)
					if c.afflictions[i].strength > 80 then
						c.afflictions.aafn_overdose.strength = c.afflictions.aafn_overdose.strength + (10 * NT.Deltatime)
					end
				end
				if c.afflictions.drunk.strength > 25 then
					HF.Explode(c.character, 50, 5, 100, 2, 100, 0, 0)
				end
			end
		end
	}
}


-- Add to Neuro Limb Afflictions.
for k, v in pairs(NTTHERM.UpdateLimbAfflictions) do
	NT.LimbAfflictions[k] = v
end

-- Add to Neuro Afflictions.
for k, v in pairs(NTTHERM.UpdateAfflictions) do
	NT.Afflictions[k] = v
end

-- Add to neuro afflictions
for k, v in pairs(NTTHERM.UpdateBloodAfflictions) do 
	NT.Afflictions[k] = v
end

-- Add blood afflictions to the hema anaylzer.
for index, value in pairs(FetchOtherStats().BloodAfflictions) do
	NTC.AddHematologyAffliction(value)
end
