-- MoltenCodes ApiKit: Retail bindings (wow.retail.api)
--
-- GENERATED FILE. Do not edit. Regenerate with `python3 -m tooling.api.generate`.
-- Source: Gethe/wow-ui-source@09b9db7948abc9b9648dedaab51eb0cf3ee67b31 (live),
-- client 12.1.0, build 69933, captured 2026-09-24.
--
-- Every entry is a direct alias of the host function, bound only when the
-- running client has it. See docs/API_KIT_DESIGN.md, section 7.2.

-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, 2) or nil
if Registry == nil and type(namespace) == "table" then
  Registry = rawget(namespace, "Registry")
end
if type(Registry) ~= "table" or rawget(Registry, "API") ~= 2 then
  error("MoltenCodes ApiKit (Retail bindings) requires Registry API 2 to be loaded first", 2)
end

local getPackage = rawget(Registry, "Get")
if type(getPackage) ~= "function" then
  error("MoltenCodes ApiKit (Retail bindings) requires a valid Registry API 2 facade", 2)
end
local ApiKit = getPackage(Registry, "apiKit", 1)
if
  type(ApiKit) ~= "table"
  or rawget(ApiKit, "API") ~= 1
  or type(rawget(ApiKit, "RegisterFlavor")) ~= "function"
then
  error("MoltenCodes ApiKit (Retail bindings) requires ApiKit API 1 to be loaded first", 2)
end

ApiKit:RegisterFlavor("retail", function(api, host)
  do
    local source = host.C_AccessibilityOptions
    if source then
      local target = {}
      api.accessibilityOptions = target
    end
  end
  do
    local source = host.C_AccountInfo
    if source then
      local target = {}
      api.accountInfo = target
      target.getIDFromBattleNetAccountGUID = source.GetIDFromBattleNetAccountGUID
      target.isGUIDBattleNetAccountType = source.IsGUIDBattleNetAccountType
      target.isGUIDRelatedToLocalAccount = source.IsGUIDRelatedToLocalAccount
    end
  end
  do
    local source = host.C_AccountStore
    if source then
      local target = {}
      api.accountStore = target
      target.beginPurchase = source.BeginPurchase
      target.getCategories = source.GetCategories
      target.getCategoryInfo = source.GetCategoryInfo
      target.getCategoryItems = source.GetCategoryItems
      target.getCurrencyAvailable = source.GetCurrencyAvailable
      target.getCurrencyIDForStore = source.GetCurrencyIDForStore
      target.getCurrencyInfo = source.GetCurrencyInfo
      target.getItemInfo = source.GetItemInfo
      target.getStoreFrontState = source.GetStoreFrontState
      target.refundItem = source.RefundItem
      target.requestStoreFrontInfoUpdate = source.RequestStoreFrontInfoUpdate
    end
  end
  do
    local source = host.C_AchievementInfo
    if source then
      local target = {}
      api.achievementInfo = target
      target.areGuildAchievementsEnabled = source.AreGuildAchievementsEnabled
      target.getRewardItemID = source.GetRewardItemID
      target.getSupercedingAchievements = source.GetSupercedingAchievements
      target.isGuildAchievement = source.IsGuildAchievement
      target.isValidAchievement = source.IsValidAchievement
      target.setPortraitTexture = source.SetPortraitTexture
    end
  end
  do
    local source = host.C_AchievementTelemetry
    if source then
      local target = {}
      api.achievementTelemetry = target
      target.linkAchievementInClub = source.LinkAchievementInClub
      target.linkAchievementInWhisper = source.LinkAchievementInWhisper
      target.showAchievements = source.ShowAchievements
    end
  end
  do
    local source = host.C_ActionBar
    if source then
      local target = {}
      api.actionBar = target
      target.enableActionRangeCheck = source.EnableActionRangeCheck
      target.findAssistedCombatActionButtons = source.FindAssistedCombatActionButtons
      target.findFlyoutActionButtons = source.FindFlyoutActionButtons
      target.findPetActionButtons = source.FindPetActionButtons
      target.findSpellActionButtons = source.FindSpellActionButtons
      target.forceUpdateAction = source.ForceUpdateAction
      target.getActionAutocast = source.GetActionAutocast
      target.getActionBarPage = source.GetActionBarPage
      target.getActionChargeDuration = source.GetActionChargeDuration
      target.getActionCharges = source.GetActionCharges
      target.getActionCooldown = source.GetActionCooldown
      target.getActionCooldownDuration = source.GetActionCooldownDuration
      target.getActionDisplayCount = source.GetActionDisplayCount
      target.getActionLossOfControlCooldownDuration = source.GetActionLossOfControlCooldownDuration
      target.getActionLossOfControlCooldownInfo = source.GetActionLossOfControlCooldownInfo
      target.getActionText = source.GetActionText
      target.getActionTexture = source.GetActionTexture
      target.getActionUseCount = source.GetActionUseCount
      target.getBonusBarIndex = source.GetBonusBarIndex
      target.getBonusBarIndexForSlot = source.GetBonusBarIndexForSlot
      target.getBonusBarOffset = source.GetBonusBarOffset
      target.getExtraBarIndex = source.GetExtraBarIndex
      target.getItemActionOnEquipSpellID = source.GetItemActionOnEquipSpellID
      target.getMultiCastBarIndex = source.GetMultiCastBarIndex
      target.getOverrideBarIndex = source.GetOverrideBarIndex
      target.getOverrideBarSkin = source.GetOverrideBarSkin
      target.getPetActionPetBarIndices = source.GetPetActionPetBarIndices
      target.getProfessionQuality = source.GetProfessionQuality
      target.getProfessionQualityInfo = source.GetProfessionQualityInfo
      target.getSpell = source.GetSpell
      target.getTempShapeshiftBarIndex = source.GetTempShapeshiftBarIndex
      target.getVehicleBarIndex = source.GetVehicleBarIndex
      target.hasAction = source.HasAction
      target.hasAssistedCombatActionButtons = source.HasAssistedCombatActionButtons
      target.hasBonusActionBar = source.HasBonusActionBar
      target.hasExtraActionBar = source.HasExtraActionBar
      target.hasFlyoutActionButtons = source.HasFlyoutActionButtons
      target.hasOverrideActionBar = source.HasOverrideActionBar
      target.hasPetActionButtons = source.HasPetActionButtons
      target.hasPetActionPetBarIndices = source.HasPetActionPetBarIndices
      target.hasRangeRequirements = source.HasRangeRequirements
      target.hasSpellActionButtons = source.HasSpellActionButtons
      target.hasTempShapeshiftActionBar = source.HasTempShapeshiftActionBar
      target.hasVehicleActionBar = source.HasVehicleActionBar
      target.isActionInRange = source.IsActionInRange
      target.isAssistedCombatAction = source.IsAssistedCombatAction
      target.isAttackAction = source.IsAttackAction
      target.isAutoCastPetAction = source.IsAutoCastPetAction
      target.isAutoRepeatAction = source.IsAutoRepeatAction
      target.isConsumableAction = source.IsConsumableAction
      target.isCurrentAction = source.IsCurrentAction
      target.isEnabledAutoCastPetAction = source.IsEnabledAutoCastPetAction
      target.isEquippedAction = source.IsEquippedAction
      target.isEquippedGearOutfitAction = source.IsEquippedGearOutfitAction
      target.isHarmfulAction = source.IsHarmfulAction
      target.isHelpfulAction = source.IsHelpfulAction
      target.isInterruptAction = source.IsInterruptAction
      target.isItemAction = source.IsItemAction
      target.isOnBarOrSpecialBar = source.IsOnBarOrSpecialBar
      target.isPossessBarVisible = source.IsPossessBarVisible
      target.isStackableAction = source.IsStackableAction
      target.isUsableAction = source.IsUsableAction
      target.putActionInSlot = source.PutActionInSlot
      target.registerActionUIButton = source.RegisterActionUIButton
      target.setActionBarPage = source.SetActionBarPage
      target.shouldOverrideBarShowHealthBar = source.ShouldOverrideBarShowHealthBar
      target.shouldOverrideBarShowManaBar = source.ShouldOverrideBarShowManaBar
      target.toggleAutoCastPetAction = source.ToggleAutoCastPetAction
      target.unregisterActionUIButton = source.UnregisterActionUIButton
      target.usesActionText = source.UsesActionText
    end
  end
  do
    local source = host.C_AddOnProfiler
    if source then
      local target = {}
      api.addOnProfiler = target
      api.profiler = target
      target.addMeasuredCallEvent = source.AddMeasuredCallEvent
      target.addPerformanceMessageShown = source.AddPerformanceMessageShown
      target.checkForPerformanceMessage = source.CheckForPerformanceMessage
      target.getAddOnMetric = source.GetAddOnMetric
      target.getApplicationMetric = source.GetApplicationMetric
      target.getOverallMetric = source.GetOverallMetric
      target.getTicksPerSecond = source.GetTicksPerSecond
      target.getTopKAddOnsForMetric = source.GetTopKAddOnsForMetric
      target.isEnabled = source.IsEnabled
      target.measureCall = source.MeasureCall
    end
  end
  do
    local source = host.C_AddOns
    if source then
      local target = {}
      api.addOns = target
      target.disableAddOn = source.DisableAddOn
      target.disableAllAddOns = source.DisableAllAddOns
      target.doesAddOnExist = source.DoesAddOnExist
      target.doesAddOnHaveLoadError = source.DoesAddOnHaveLoadError
      target.enableAddOn = source.EnableAddOn
      target.enableAllAddOns = source.EnableAllAddOns
      target.getAddOnDependencies = source.GetAddOnDependencies
      target.getAddOnEnableState = source.GetAddOnEnableState
      target.getAddOnInfo = source.GetAddOnInfo
      target.getAddOnInterfaceVersion = source.GetAddOnInterfaceVersion
      target.getAddOnLocalTable = source.GetAddOnLocalTable
      target.getAddOnMetadata = source.GetAddOnMetadata
      target.getAddOnName = source.GetAddOnName
      target.getAddOnNotes = source.GetAddOnNotes
      target.getAddOnOptionalDependencies = source.GetAddOnOptionalDependencies
      target.getAddOnSecurity = source.GetAddOnSecurity
      target.getAddOnTitle = source.GetAddOnTitle
      target.getNumAddOns = source.GetNumAddOns
      target.getScriptsDisallowedForBeta = source.GetScriptsDisallowedForBeta
      target.isAddOnDefaultEnabled = source.IsAddOnDefaultEnabled
      target.isAddOnLoadOnDemand = source.IsAddOnLoadOnDemand
      target.isAddOnLoadable = source.IsAddOnLoadable
      target.isAddOnLoaded = source.IsAddOnLoaded
      target.isAddonVersionCheckEnabled = source.IsAddonVersionCheckEnabled
      target.loadAddOn = source.LoadAddOn
      target.resetAddOns = source.ResetAddOns
      target.resetDisabledAddOns = source.ResetDisabledAddOns
      target.saveAddOns = source.SaveAddOns
      target.setAddonVersionCheck = source.SetAddonVersionCheck
    end
  end
  do
    local source = host.C_AdventureJournal
    if source then
      local target = {}
      api.adventureJournal = target
    end
  end
  do
    local source = host.C_AdventureMap
    if source then
      local target = {}
      api.adventureMap = target
      target.getAdventureMapTextureKit = source.GetAdventureMapTextureKit
      target.getQuestPortraitInfo = source.GetQuestPortraitInfo
    end
  end
  do
    local source = host.C_AlliedRaces
    if source then
      local target = {}
      api.alliedRaces = target
      target.getAllRacialAbilitiesFromID = source.GetAllRacialAbilitiesFromID
      target.getRaceInfoByID = source.GetRaceInfoByID
    end
  end
  do
    local source = host.C_AnimaDiversion
    if source then
      local target = {}
      api.animaDiversion = target
      target.closeUI = source.CloseUI
      target.getAnimaDiversionNodes = source.GetAnimaDiversionNodes
      target.getOriginPosition = source.GetOriginPosition
      target.getReinforceProgress = source.GetReinforceProgress
      target.getTextureKit = source.GetTextureKit
      target.openAnimaDiversionUI = source.OpenAnimaDiversionUI
      target.selectAnimaNode = source.SelectAnimaNode
    end
  end
  do
    local source = host.C_ArdenwealdGardening
    if source then
      local target = {}
      api.ardenwealdGardening = target
      target.getGardenData = source.GetGardenData
      target.isGardenAccessible = source.IsGardenAccessible
    end
  end
  do
    local source = host.C_AreaPoiInfo
    if source then
      local target = {}
      api.areaPoiInfo = target
      target.getAreaPOIForMap = source.GetAreaPOIForMap
      target.getAreaPOIInfo = source.GetAreaPOIInfo
      target.getAreaPOISecondsLeft = source.GetAreaPOISecondsLeft
      target.getDelvesForMap = source.GetDelvesForMap
      target.getDragonridingRacesForMap = source.GetDragonridingRacesForMap
      target.getEventsForMap = source.GetEventsForMap
      target.getQuestHubsForMap = source.GetQuestHubsForMap
      target.isAreaPOITimed = source.IsAreaPOITimed
    end
  end
  do
    local source = host.C_ArtifactUI
    if source then
      local target = {}
      api.artifactUI = target
      target.addPower = source.AddPower
      target.applyCursorRelicToSlot = source.ApplyCursorRelicToSlot
      target.canApplyArtifactRelic = source.CanApplyArtifactRelic
      target.canApplyCursorRelicToSlot = source.CanApplyCursorRelicToSlot
      target.canApplyRelicItemIDToEquippedArtifactSlot =
        source.CanApplyRelicItemIDToEquippedArtifactSlot
      target.canApplyRelicItemIDToSlot = source.CanApplyRelicItemIDToSlot
      target.checkRespecNPC = source.CheckRespecNPC
      target.clear = source.Clear
      target.clearForgeCamera = source.ClearForgeCamera
      target.confirmRespec = source.ConfirmRespec
      target.doesEquippedArtifactHaveAnyRelicsSlotted =
        source.DoesEquippedArtifactHaveAnyRelicsSlotted
      target.getAppearanceInfo = source.GetAppearanceInfo
      target.getAppearanceInfoByID = source.GetAppearanceInfoByID
      target.getAppearanceSetInfo = source.GetAppearanceSetInfo
      target.getArtifactArtInfo = source.GetArtifactArtInfo
      target.getArtifactInfo = source.GetArtifactInfo
      target.getArtifactItemID = source.GetArtifactItemID
      target.getArtifactTier = source.GetArtifactTier
      target.getArtifactXPRewardTargetInfo = source.GetArtifactXPRewardTargetInfo
      target.getCostForPointAtRank = source.GetCostForPointAtRank
      target.getEquippedArtifactArtInfo = source.GetEquippedArtifactArtInfo
      target.getEquippedArtifactInfo = source.GetEquippedArtifactInfo
      target.getEquippedArtifactItemID = source.GetEquippedArtifactItemID
      target.getEquippedArtifactNumRelicSlots = source.GetEquippedArtifactNumRelicSlots
      target.getEquippedArtifactRelicInfo = source.GetEquippedArtifactRelicInfo
      target.getEquippedRelicLockedReason = source.GetEquippedRelicLockedReason
      target.getForgeRotation = source.GetForgeRotation
      target.getItemLevelIncreaseProvidedByRelic = source.GetItemLevelIncreaseProvidedByRelic
      target.getMetaPowerInfo = source.GetMetaPowerInfo
      target.getNumAppearanceSets = source.GetNumAppearanceSets
      target.getNumObtainedArtifacts = source.GetNumObtainedArtifacts
      target.getNumRelicSlots = source.GetNumRelicSlots
      target.getPointsRemaining = source.GetPointsRemaining
      target.getPowerHyperlink = source.GetPowerHyperlink
      target.getPowerInfo = source.GetPowerInfo
      target.getPowerLinks = source.GetPowerLinks
      target.getPowers = source.GetPowers
      target.getPowersAffectedByRelic = source.GetPowersAffectedByRelic
      target.getPowersAffectedByRelicItemLink = source.GetPowersAffectedByRelicItemLink
      target.getPreviewAppearance = source.GetPreviewAppearance
      target.getRelicInfo = source.GetRelicInfo
      target.getRelicInfoByItemID = source.GetRelicInfoByItemID
      target.getRelicLockedReason = source.GetRelicLockedReason
      target.getRelicSlotType = source.GetRelicSlotType
      target.getRespecArtifactArtInfo = source.GetRespecArtifactArtInfo
      target.getRespecArtifactInfo = source.GetRespecArtifactInfo
      target.getRespecCost = source.GetRespecCost
      target.getTotalPowerCost = source.GetTotalPowerCost
      target.getTotalPurchasedRanks = source.GetTotalPurchasedRanks
      target.isArtifactDisabled = source.IsArtifactDisabled
      target.isArtifactItem = source.IsArtifactItem
      target.isAtForge = source.IsAtForge
      target.isEquippedArtifactDisabled = source.IsEquippedArtifactDisabled
      target.isEquippedArtifactMaxed = source.IsEquippedArtifactMaxed
      target.isMaxedByRulesOrEffect = source.IsMaxedByRulesOrEffect
      target.isPowerKnown = source.IsPowerKnown
      target.isViewedArtifactEquipped = source.IsViewedArtifactEquipped
      target.setAppearance = source.SetAppearance
      target.setForgeCamera = source.SetForgeCamera
      target.setForgeRotation = source.SetForgeRotation
      target.setPreviewAppearance = source.SetPreviewAppearance
      target.shouldSuppressForgeRotation = source.ShouldSuppressForgeRotation
    end
  end
  do
    local source = host.C_AssistedCombat
    if source then
      local target = {}
      api.assistedCombat = target
      target.getActionSpell = source.GetActionSpell
      target.getNextCastSpell = source.GetNextCastSpell
      target.getRotationSpells = source.GetRotationSpells
      target.isAvailable = source.IsAvailable
    end
  end
  do
    local source = host.C_AuctionHouse
    if source then
      local target = {}
      api.auctionHouse = target
      target.calculateCommodityDeposit = source.CalculateCommodityDeposit
      target.calculateItemDeposit = source.CalculateItemDeposit
      target.canCancelAuction = source.CanCancelAuction
      target.cancelAuction = source.CancelAuction
      target.cancelCommoditiesPurchase = source.CancelCommoditiesPurchase
      target.cancelSell = source.CancelSell
      target.closeAuctionHouse = source.CloseAuctionHouse
      target.confirmCommoditiesPurchase = source.ConfirmCommoditiesPurchase
      target.confirmPostCommodity = source.ConfirmPostCommodity
      target.confirmPostItem = source.ConfirmPostItem
      target.favoritesAreAvailable = source.FavoritesAreAvailable
      target.getAuctionInfoByID = source.GetAuctionInfoByID
      target.getAuctionItemSubClasses = source.GetAuctionItemSubClasses
      target.getAvailablePostCount = source.GetAvailablePostCount
      target.getBidInfo = source.GetBidInfo
      target.getBidType = source.GetBidType
      target.getBids = source.GetBids
      target.getBrowseResults = source.GetBrowseResults
      target.getCancelCost = source.GetCancelCost
      target.getCommoditySearchResultInfo = source.GetCommoditySearchResultInfo
      target.getCommoditySearchResultsQuantity = source.GetCommoditySearchResultsQuantity
      target.getExtraBrowseInfo = source.GetExtraBrowseInfo
      target.getFilterGroups = source.GetFilterGroups
      target.getItemCommodityStatus = source.GetItemCommodityStatus
      target.getItemKeyFromItem = source.GetItemKeyFromItem
      target.getItemKeyInfo = source.GetItemKeyInfo
      target.getItemKeyRequiredLevel = source.GetItemKeyRequiredLevel
      target.getItemSearchResultInfo = source.GetItemSearchResultInfo
      target.getItemSearchResultsQuantity = source.GetItemSearchResultsQuantity
      target.getMaxBidItemBid = source.GetMaxBidItemBid
      target.getMaxBidItemBuyout = source.GetMaxBidItemBuyout
      target.getMaxCommoditySearchResultPrice = source.GetMaxCommoditySearchResultPrice
      target.getMaxItemSearchResultBid = source.GetMaxItemSearchResultBid
      target.getMaxItemSearchResultBuyout = source.GetMaxItemSearchResultBuyout
      target.getMaxOwnedAuctionBid = source.GetMaxOwnedAuctionBid
      target.getMaxOwnedAuctionBuyout = source.GetMaxOwnedAuctionBuyout
      target.getNumBidTypes = source.GetNumBidTypes
      target.getNumBids = source.GetNumBids
      target.getNumCommoditySearchResults = source.GetNumCommoditySearchResults
      target.getNumItemSearchResults = source.GetNumItemSearchResults
      target.getNumOwnedAuctionTypes = source.GetNumOwnedAuctionTypes
      target.getNumOwnedAuctions = source.GetNumOwnedAuctions
      target.getNumReplicateItems = source.GetNumReplicateItems
      target.getOwnedAuctionInfo = source.GetOwnedAuctionInfo
      target.getOwnedAuctionType = source.GetOwnedAuctionType
      target.getOwnedAuctions = source.GetOwnedAuctions
      target.getQuoteDurationRemaining = source.GetQuoteDurationRemaining
      target.getReplicateItemBattlePetInfo = source.GetReplicateItemBattlePetInfo
      target.getReplicateItemInfo = source.GetReplicateItemInfo
      target.getReplicateItemLink = source.GetReplicateItemLink
      target.getReplicateItemTimeLeft = source.GetReplicateItemTimeLeft
      target.getTimeLeftBandInfo = source.GetTimeLeftBandInfo
      target.hasFavorites = source.HasFavorites
      target.hasFullBidResults = source.HasFullBidResults
      target.hasFullBrowseResults = source.HasFullBrowseResults
      target.hasFullCommoditySearchResults = source.HasFullCommoditySearchResults
      target.hasFullItemSearchResults = source.HasFullItemSearchResults
      target.hasFullOwnedAuctionResults = source.HasFullOwnedAuctionResults
      target.hasMaxFavorites = source.HasMaxFavorites
      target.hasSearchResults = source.HasSearchResults
      target.isFavoriteItem = source.IsFavoriteItem
      target.isSellItemValid = source.IsSellItemValid
      target.isThrottledMessageSystemReady = source.IsThrottledMessageSystemReady
      target.makeItemKey = source.MakeItemKey
      target.placeBid = source.PlaceBid
      target.postCommodity = source.PostCommodity
      target.postItem = source.PostItem
      target.queryBids = source.QueryBids
      target.queryOwnedAuctions = source.QueryOwnedAuctions
      target.refreshCommoditySearchResults = source.RefreshCommoditySearchResults
      target.refreshItemSearchResults = source.RefreshItemSearchResults
      target.replicateItems = source.ReplicateItems
      target.requestMoreBrowseResults = source.RequestMoreBrowseResults
      target.requestMoreCommoditySearchResults = source.RequestMoreCommoditySearchResults
      target.requestMoreItemSearchResults = source.RequestMoreItemSearchResults
      target.requestOwnedAuctionBidderInfo = source.RequestOwnedAuctionBidderInfo
      target.searchForFavorites = source.SearchForFavorites
      target.searchForItemKeys = source.SearchForItemKeys
      target.sendBrowseQuery = source.SendBrowseQuery
      target.sendSearchQuery = source.SendSearchQuery
      target.sendSellSearchQuery = source.SendSellSearchQuery
      target.setFavoriteItem = source.SetFavoriteItem
      target.shouldAutoPopulatePrice = source.ShouldAutoPopulatePrice
      target.startCommoditiesPurchase = source.StartCommoditiesPurchase
      target.supportsCopperValues = source.SupportsCopperValues
    end
  end
  do
    local source = host.C_AuraContainerUtil
    if source then
      local target = {}
      api.auraContainerUtil = target
      target.processAuraTooltipBackdropOptions = source.ProcessAuraTooltipBackdropOptions
      target.processAuraTooltipNineSliceOptions = source.ProcessAuraTooltipNineSliceOptions
      target.processAuraTooltipTextureSliceOptions = source.ProcessAuraTooltipTextureSliceOptions
      target.processCustomAuraButtonApplicationBarOptions =
        source.ProcessCustomAuraButtonApplicationBarOptions
      target.processCustomAuraButtonApplicationCountOptions =
        source.ProcessCustomAuraButtonApplicationCountOptions
      target.processCustomAuraButtonDispelTypeTextOptions =
        source.ProcessCustomAuraButtonDispelTypeTextOptions
      target.processCustomAuraButtonDispelTypeTextureOptions =
        source.ProcessCustomAuraButtonDispelTypeTextureOptions
      target.processCustomAuraButtonDurationBarOptions =
        source.ProcessCustomAuraButtonDurationBarOptions
      target.processCustomAuraButtonDurationTextOptions =
        source.ProcessCustomAuraButtonDurationTextOptions
    end
  end
  do
    local source = host.C_AutoComplete
    if source then
      local target = {}
      api.autoComplete = target
      target.getAutoCompletePresenceID = source.GetAutoCompletePresenceID
      target.getAutoCompleteRealms = source.GetAutoCompleteRealms
      target.getAutoCompleteResults = source.GetAutoCompleteResults
      target.isRecognizedName = source.IsRecognizedName
    end
  end
  do
    local source = host.C_AzeriteEmpoweredItem
    if source then
      local target = {}
      api.azeriteEmpoweredItem = target
      target.canSelectPower = source.CanSelectPower
      target.confirmAzeriteEmpoweredItemRespec = source.ConfirmAzeriteEmpoweredItemRespec
      target.getAllTierInfo = source.GetAllTierInfo
      target.getAllTierInfoByItemID = source.GetAllTierInfoByItemID
      target.getAzeriteEmpoweredItemRespecCost = source.GetAzeriteEmpoweredItemRespecCost
      target.getPowerInfo = source.GetPowerInfo
      target.getPowerText = source.GetPowerText
      target.getSpecsForPower = source.GetSpecsForPower
      target.hasAnyUnselectedPowers = source.HasAnyUnselectedPowers
      target.hasBeenViewed = source.HasBeenViewed
      target.isAzeriteEmpoweredItem = source.IsAzeriteEmpoweredItem
      target.isAzeriteEmpoweredItemByID = source.IsAzeriteEmpoweredItemByID
      target.isAzeritePreviewSourceDisplayable = source.IsAzeritePreviewSourceDisplayable
      target.isHeartOfAzerothEquipped = source.IsHeartOfAzerothEquipped
      target.isPowerAvailableForSpec = source.IsPowerAvailableForSpec
      target.isPowerSelected = source.IsPowerSelected
      target.selectPower = source.SelectPower
      target.setHasBeenViewed = source.SetHasBeenViewed
    end
  end
  do
    local source = host.C_AzeriteEssence
    if source then
      local target = {}
      api.azeriteEssence = target
      target.activateEssence = source.ActivateEssence
      target.canActivateEssence = source.CanActivateEssence
      target.canDeactivateEssence = source.CanDeactivateEssence
      target.canOpenUI = source.CanOpenUI
      target.clearPendingActivationEssence = source.ClearPendingActivationEssence
      target.closeForge = source.CloseForge
      target.getEssenceHyperlink = source.GetEssenceHyperlink
      target.getEssenceInfo = source.GetEssenceInfo
      target.getEssences = source.GetEssences
      target.getMilestoneEssence = source.GetMilestoneEssence
      target.getMilestoneInfo = source.GetMilestoneInfo
      target.getMilestoneSpell = source.GetMilestoneSpell
      target.getMilestones = source.GetMilestones
      target.getNumUnlockedEssences = source.GetNumUnlockedEssences
      target.getNumUsableEssences = source.GetNumUsableEssences
      target.getPendingActivationEssence = source.GetPendingActivationEssence
      target.hasNeverActivatedAnyEssences = source.HasNeverActivatedAnyEssences
      target.hasPendingActivationEssence = source.HasPendingActivationEssence
      target.isAtForge = source.IsAtForge
      target.setPendingActivationEssence = source.SetPendingActivationEssence
      target.unlockMilestone = source.UnlockMilestone
    end
  end
  do
    local source = host.C_AzeriteItem
    if source then
      local target = {}
      api.azeriteItem = target
      target.findActiveAzeriteItem = source.FindActiveAzeriteItem
      target.getAzeriteItemXPInfo = source.GetAzeriteItemXPInfo
      target.getPowerLevel = source.GetPowerLevel
      target.getUnlimitedPowerLevel = source.GetUnlimitedPowerLevel
      target.hasActiveAzeriteItem = source.HasActiveAzeriteItem
      target.isAzeriteItem = source.IsAzeriteItem
      target.isAzeriteItemAtMaxLevel = source.IsAzeriteItemAtMaxLevel
      target.isAzeriteItemByID = source.IsAzeriteItemByID
      target.isAzeriteItemEnabled = source.IsAzeriteItemEnabled
      target.isUnlimitedLevelingUnlocked = source.IsUnlimitedLevelingUnlocked
    end
  end
  do
    local target = {}
    api.bagIndexConstants = target
  end
  do
    local source = host.C_Bank
    if source then
      local target = {}
      api.bank = target
      target.areAnyBankTypesViewable = source.AreAnyBankTypesViewable
      target.autoDepositItemsIntoBank = source.AutoDepositItemsIntoBank
      target.canDepositMoney = source.CanDepositMoney
      target.canPurchaseBankTab = source.CanPurchaseBankTab
      target.canUseBank = source.CanUseBank
      target.canViewBank = source.CanViewBank
      target.canWithdrawMoney = source.CanWithdrawMoney
      target.closeBankFrame = source.CloseBankFrame
      target.depositMoney = source.DepositMoney
      target.doesBankTypeSupportAutoDeposit = source.DoesBankTypeSupportAutoDeposit
      target.doesBankTypeSupportMoneyTransfer = source.DoesBankTypeSupportMoneyTransfer
      target.fetchBankLockedReason = source.FetchBankLockedReason
      target.fetchDepositedMoney = source.FetchDepositedMoney
      target.fetchNextPurchasableBankTabData = source.FetchNextPurchasableBankTabData
      target.fetchNumPurchasedBankTabs = source.FetchNumPurchasedBankTabs
      target.fetchPurchasedBankTabData = source.FetchPurchasedBankTabData
      target.fetchPurchasedBankTabIDs = source.FetchPurchasedBankTabIDs
      target.fetchViewableBankTypes = source.FetchViewableBankTypes
      target.hasMaxBankTabs = source.HasMaxBankTabs
      target.isItemAllowedInBankType = source.IsItemAllowedInBankType
      target.purchaseBankTab = source.PurchaseBankTab
      target.updateBankTabSettings = source.UpdateBankTabSettings
      target.withdrawMoney = source.WithdrawMoney
    end
  end
  do
    local source = host.C_BarberShop
    if source then
      local target = {}
      api.barberShop = target
      target.applyCustomizationChoices = source.ApplyCustomizationChoices
      target.cancel = source.Cancel
      target.clearPreviewChoices = source.ClearPreviewChoices
      target.getAvailableCustomizations = source.GetAvailableCustomizations
      target.getCurrentCameraZoom = source.GetCurrentCameraZoom
      target.getCurrentCharacterData = source.GetCurrentCharacterData
      target.getCurrentCost = source.GetCurrentCost
      target.getViewingChrModel = source.GetViewingChrModel
      target.hasAlteredForm = source.HasAlteredForm
      target.hasAnyChanges = source.HasAnyChanges
      target.hasCustomizationFeature = source.HasCustomizationFeature
      target.isViewingAlteredForm = source.IsViewingAlteredForm
      target.markCustomizationChoiceAsSeen = source.MarkCustomizationChoiceAsSeen
      target.markCustomizationOptionAsSeen = source.MarkCustomizationOptionAsSeen
      target.previewCustomizationChoice = source.PreviewCustomizationChoice
      target.randomizeCustomizationChoices = source.RandomizeCustomizationChoices
      target.resetCameraRotation = source.ResetCameraRotation
      target.resetCustomizationChoices = source.ResetCustomizationChoices
      target.rotateCamera = source.RotateCamera
      target.saveSeenChoices = source.SaveSeenChoices
      target.setCameraDistanceOffset = source.SetCameraDistanceOffset
      target.setCameraZoomLevel = source.SetCameraZoomLevel
      target.setCustomizationChoice = source.SetCustomizationChoice
      target.setModelDressState = source.SetModelDressState
      target.setSelectedSex = source.SetSelectedSex
      target.setViewingAlteredForm = source.SetViewingAlteredForm
      target.setViewingChrModel = source.SetViewingChrModel
      target.setViewingShapeshiftForm = source.SetViewingShapeshiftForm
      target.zoomCamera = source.ZoomCamera
    end
  end
  do
    local source = host.C_BarberShopInternal
    if source then
      local target = {}
      api.barberShopInternal = target
      target.setQAMode = source.SetQAMode
    end
  end
  do
    local source = host.C_BattleNet
    if source then
      local target = {}
      api.battleNet = target
      target.areFriendTagsEnabled = source.AreFriendTagsEnabled
      target.areTitleFriendCustomNamesEnabled = source.AreTitleFriendCustomNamesEnabled
      target.areTitleFriendsEnabled = source.AreTitleFriendsEnabled
      target.bnCheckBattleTagInviteToRecentAlly = source.BNCheckBattleTagInviteToRecentAlly
      target.bnCheckTitleFriendInviteToUnit = source.BNCheckTitleFriendInviteToUnit
      target.canToggleHighResTexturesWithoutClientReload =
        source.CanToggleHighResTexturesWithoutClientReload
      target.getAccountInfoByGUID = source.GetAccountInfoByGUID
      target.getAccountInfoByID = source.GetAccountInfoByID
      target.getCustomTitleFriendName = source.GetCustomTitleFriendName
      target.getFriendAccountInfo = source.GetFriendAccountInfo
      target.getFriendGameAccountInfo = source.GetFriendGameAccountInfo
      target.getFriendInviteInfo = source.GetFriendInviteInfo
      target.getFriendNumGameAccounts = source.GetFriendNumGameAccounts
      target.getGameAccountInfoByGUID = source.GetGameAccountInfoByGUID
      target.getGameAccountInfoByID = source.GetGameAccountInfoByID
      target.installHighResTextures = source.InstallHighResTextures
      target.inviteFriend = source.InviteFriend
      target.isBattleNetFriendsListEnabled = source.IsBattleNetFriendsListEnabled
      target.isBattleNetFriendsListSupported = source.IsBattleNetFriendsListSupported
      target.searchFriends = source.SearchFriends
      target.sendGameData = source.SendGameData
      target.sendTitleFriendInviteByName = source.SendTitleFriendInviteByName
      target.sendVerifiedBattleNetFriendInvite = source.SendVerifiedBattleNetFriendInvite
      target.sendWhisper = source.SendWhisper
      target.setAFK = source.SetAFK
      target.setAppearOffline = source.SetAppearOffline
      target.setCustomMessage = source.SetCustomMessage
      target.setCustomTitleFriendName = source.SetCustomTitleFriendName
      target.setDND = source.SetDND
      target.setFriendTags = source.SetFriendTags
    end
  end
  do
    local source = host.C_BattlePet
    if source then
      local target = {}
      api.battlePet = target
    end
  end
  do
    local source = host.C_BehavioralMessaging
    if source then
      local target = {}
      api.behavioralMessaging = target
      target.sendNotificationReceipt = source.SendNotificationReceipt
    end
  end
  do
    local source = host.C_BlackMarketInfo
    if source then
      local target = {}
      api.blackMarketInfo = target
    end
  end
  do
    local target = {}
    api.bnetOutage = target
    target.clearOutage = host.ClearOutage
    target.outageDetected = host.OutageDetected
  end
  do
    local source = host.C_Browser
    if source then
      local target = {}
      api.browser = target
      target.closeFullscreenBrowser = source.CloseFullscreenBrowser
    end
  end
  do
    local target = {}
    api.build = target
    target.getBuildInfo = host.GetBuildInfo
    target.getBuildOption = host.GetBuildOption
    target.is64BitClient = host.Is64BitClient
    target.isBetaBuild = host.IsBetaBuild
    target.isDebugBuild = host.IsDebugBuild
    target.isLinuxClient = host.IsLinuxClient
    target.isMacClient = host.IsMacClient
    target.isPublicBuild = host.IsPublicBuild
    target.isPublicTestClient = host.IsPublicTestClient
    target.isTestBuild = host.IsTestBuild
    target.isWindowsClient = host.IsWindowsClient
    target.supportsClipCursor = host.SupportsClipCursor
  end
  do
    local source = host.C_Calendar
    if source then
      local target = {}
      api.calendar = target
      target.addEvent = source.AddEvent
      target.areNamesReady = source.AreNamesReady
      target.canAddEvent = source.CanAddEvent
      target.canSendInvite = source.CanSendInvite
      target.closeEvent = source.CloseEvent
      target.contextMenuEventCanComplain = source.ContextMenuEventCanComplain
      target.contextMenuEventCanEdit = source.ContextMenuEventCanEdit
      target.contextMenuEventCanRemove = source.ContextMenuEventCanRemove
      target.contextMenuEventClipboard = source.ContextMenuEventClipboard
      target.contextMenuEventCopy = source.ContextMenuEventCopy
      target.contextMenuEventGetCalendarType = source.ContextMenuEventGetCalendarType
      target.contextMenuEventPaste = source.ContextMenuEventPaste
      target.contextMenuEventRemove = source.ContextMenuEventRemove
      target.contextMenuEventSignUp = source.ContextMenuEventSignUp
      target.contextMenuGetEventIndex = source.ContextMenuGetEventIndex
      target.contextMenuInviteAvailable = source.ContextMenuInviteAvailable
      target.contextMenuInviteDecline = source.ContextMenuInviteDecline
      target.contextMenuInviteRemove = source.ContextMenuInviteRemove
      target.contextMenuInviteTentative = source.ContextMenuInviteTentative
      target.contextMenuSelectEvent = source.ContextMenuSelectEvent
      target.createCommunitySignUpEvent = source.CreateCommunitySignUpEvent
      target.createGuildAnnouncementEvent = source.CreateGuildAnnouncementEvent
      target.createGuildSignUpEvent = source.CreateGuildSignUpEvent
      target.createPlayerEvent = source.CreatePlayerEvent
      target.eventAvailable = source.EventAvailable
      target.eventCanEdit = source.EventCanEdit
      target.eventClearAutoApprove = source.EventClearAutoApprove
      target.eventClearLocked = source.EventClearLocked
      target.eventClearModerator = source.EventClearModerator
      target.eventDecline = source.EventDecline
      target.eventGetCalendarType = source.EventGetCalendarType
      target.eventGetClubId = source.EventGetClubId
      target.eventGetInvite = source.EventGetInvite
      target.eventGetInviteResponseTime = source.EventGetInviteResponseTime
      target.eventGetInviteSortCriterion = source.EventGetInviteSortCriterion
      target.eventGetSelectedInvite = source.EventGetSelectedInvite
      target.eventGetStatusOptions = source.EventGetStatusOptions
      target.eventGetTextures = source.EventGetTextures
      target.eventGetTypes = source.EventGetTypes
      target.eventGetTypesDisplayOrdered = source.EventGetTypesDisplayOrdered
      target.eventHasPendingInvite = source.EventHasPendingInvite
      target.eventHaveSettingsChanged = source.EventHaveSettingsChanged
      target.eventInvite = source.EventInvite
      target.eventRemoveInvite = source.EventRemoveInvite
      target.eventRemoveInviteByGuid = source.EventRemoveInviteByGuid
      target.eventSelectInvite = source.EventSelectInvite
      target.eventSetAutoApprove = source.EventSetAutoApprove
      target.eventSetClubId = source.EventSetClubId
      target.eventSetDate = source.EventSetDate
      target.eventSetDescription = source.EventSetDescription
      target.eventSetInviteStatus = source.EventSetInviteStatus
      target.eventSetLocked = source.EventSetLocked
      target.eventSetModerator = source.EventSetModerator
      target.eventSetTextureID = source.EventSetTextureID
      target.eventSetTime = source.EventSetTime
      target.eventSetTitle = source.EventSetTitle
      target.eventSetType = source.EventSetType
      target.eventSignUp = source.EventSignUp
      target.eventSortInvites = source.EventSortInvites
      target.eventTentative = source.EventTentative
      target.getClubCalendarEvents = source.GetClubCalendarEvents
      target.getDayEvent = source.GetDayEvent
      target.getDefaultGuildFilter = source.GetDefaultGuildFilter
      target.getEventIndex = source.GetEventIndex
      target.getEventIndexInfo = source.GetEventIndexInfo
      target.getEventInfo = source.GetEventInfo
      target.getFirstPendingInvite = source.GetFirstPendingInvite
      target.getGuildEventInfo = source.GetGuildEventInfo
      target.getGuildEventSelectionInfo = source.GetGuildEventSelectionInfo
      target.getHolidayInfo = source.GetHolidayInfo
      target.getMaxCreateDate = source.GetMaxCreateDate
      target.getMinDate = source.GetMinDate
      target.getMonthInfo = source.GetMonthInfo
      target.getNextClubId = source.GetNextClubId
      target.getNumDayEvents = source.GetNumDayEvents
      target.getNumGuildEvents = source.GetNumGuildEvents
      target.getNumInvites = source.GetNumInvites
      target.getNumPendingInvites = source.GetNumPendingInvites
      target.getRaidInfo = source.GetRaidInfo
      target.isActionPending = source.IsActionPending
      target.isEventOpen = source.IsEventOpen
      target.massInviteCommunity = source.MassInviteCommunity
      target.massInviteGuild = source.MassInviteGuild
      target.openCalendar = source.OpenCalendar
      target.openEvent = source.OpenEvent
      target.removeEvent = source.RemoveEvent
      target.setAbsMonth = source.SetAbsMonth
      target.setMonth = source.SetMonth
      target.setNextClubId = source.SetNextClubId
      target.updateEvent = source.UpdateEvent
    end
  end
  do
    local target = {}
    api.camera = target
    target.getCameraFOVDefaults = host.GetCameraFOVDefaults
    target.getUICameraInfo = host.GetUICameraInfo
  end
  do
    local source = host.C_CampaignInfo
    if source then
      local target = {}
      api.campaignInfo = target
      target.getAvailableCampaigns = source.GetAvailableCampaigns
      target.getCampaignChapterInfo = source.GetCampaignChapterInfo
      target.getCampaignID = source.GetCampaignID
      target.getCampaignInfo = source.GetCampaignInfo
      target.getChapterIDs = source.GetChapterIDs
      target.getCurrentChapterID = source.GetCurrentChapterID
      target.getFailureReason = source.GetFailureReason
      target.getState = source.GetState
      target.isCampaignQuest = source.IsCampaignQuest
      target.sortAsNormalQuest = source.SortAsNormalQuest
    end
  end
  do
    local source = host.C_CatalogShop
    if source then
      local target = {}
      api.catalogShop = target
      target.bulkPurchaseProducts = source.BulkPurchaseProducts
      target.bulkRefundDecors = source.BulkRefundDecors
      target.closeCatalogShopInteraction = source.CloseCatalogShopInteraction
      target.confirmHousingPurchase = source.ConfirmHousingPurchase
      target.findBestCurrencyProductForNeededAmount = source.FindBestCurrencyProductForNeededAmount
      target.getAvailableCategoryIDs = source.GetAvailableCategoryIDs
      target.getAvailableTransmogRaceInfos = source.GetAvailableTransmogRaceInfos
      target.getCatalogShopProductDisplayInfo = source.GetCatalogShopProductDisplayInfo
      target.getCategoryInfo = source.GetCategoryInfo
      target.getCategorySectionInfo = source.GetCategorySectionInfo
      target.getFailureInfo = source.GetFailureInfo
      target.getFirstCategoryByProductID = source.GetFirstCategoryByProductID
      target.getNewProducts = source.GetNewProducts
      target.getProductAvailabilityTimeRemainingSecs =
        source.GetProductAvailabilityTimeRemainingSecs
      target.getProductIDsForBundle = source.GetProductIDsForBundle
      target.getProductIDsForCategory = source.GetProductIDsForCategory
      target.getProductIDsForCategorySection = source.GetProductIDsForCategorySection
      target.getProductInfo = source.GetProductInfo
      target.getProductSortOrder = source.GetProductSortOrder
      target.getRefundableDecors = source.GetRefundableDecors
      target.getSectionIDsForCategory = source.GetSectionIDsForCategory
      target.getSpellVisualInfoForMount = source.GetSpellVisualInfoForMount
      target.getVCProductInfos = source.GetVCProductInfos
      target.getVirtualCurrencyBalance = source.GetVirtualCurrencyBalance
      target.hasNewProducts = source.HasNewProducts
      target.isProductIncludedInAnyBundle = source.IsProductIncludedInAnyBundle
      target.isShop2Enabled = source.IsShop2Enabled
      target.onLegalDisclaimerClicked = source.OnLegalDisclaimerClicked
      target.onLegalPersonalizedOptOutClicked = source.OnLegalPersonalizedOptOutClicked
      target.openCatalogShopInteractionFromHouse = source.OpenCatalogShopInteractionFromHouse
      target.openCatalogShopInteractionFromShop = source.OpenCatalogShopInteractionFromShop
      target.productDisplayedTelemetry = source.ProductDisplayedTelemetry
      target.productSelectedTelemetry = source.ProductSelectedTelemetry
      target.purchaseProduct = source.PurchaseProduct
      target.refreshRefundableDecors = source.RefreshRefundableDecors
      target.refreshVirtualCurrencyBalance = source.RefreshVirtualCurrencyBalance
      target.shouldShowHousingWarning = source.ShouldShowHousingWarning
      target.startHousingVCPurchaseConfirmation = source.StartHousingVCPurchaseConfirmation
    end
  end
  do
    local source = host.C_ChallengeMode
    if source then
      local target = {}
      api.challengeMode = target
      target.canUseKeystoneInCurrentMap = source.CanUseKeystoneInCurrentMap
      target.clearKeystone = source.ClearKeystone
      target.closeKeystoneFrame = source.CloseKeystoneFrame
      target.getActiveChallengeMapID = source.GetActiveChallengeMapID
      target.getActiveKeystoneInfo = source.GetActiveKeystoneInfo
      target.getAffixInfo = source.GetAffixInfo
      target.getChallengeCompletionInfo = source.GetChallengeCompletionInfo
      target.getDeathCount = source.GetDeathCount
      target.getDungeonScoreRarityColor = source.GetDungeonScoreRarityColor
      target.getGuildLeaders = source.GetGuildLeaders
      target.getKeystoneLevelRarityColor = source.GetKeystoneLevelRarityColor
      target.getLeaverPenaltyWarningTimeLeft = source.GetLeaverPenaltyWarningTimeLeft
      target.getMapScoreInfo = source.GetMapScoreInfo
      target.getMapTable = source.GetMapTable
      target.getMapUIInfo = source.GetMapUIInfo
      target.getOverallDungeonScore = source.GetOverallDungeonScore
      target.getPowerLevelDamageHealthMod = source.GetPowerLevelDamageHealthMod
      target.getSlottedKeystoneInfo = source.GetSlottedKeystoneInfo
      target.getSpecificDungeonOverallScoreRarityColor =
        source.GetSpecificDungeonOverallScoreRarityColor
      target.getSpecificDungeonScoreRarityColor = source.GetSpecificDungeonScoreRarityColor
      target.getStartTime = source.GetStartTime
      target.hasSlottedKeystone = source.HasSlottedKeystone
      target.isChallengeModeActive = source.IsChallengeModeActive
      target.isChallengeModeResettable = source.IsChallengeModeResettable
      target.removeKeystone = source.RemoveKeystone
      target.requestLeaders = source.RequestLeaders
      target.reset = source.Reset
      target.slotKeystone = source.SlotKeystone
      target.startChallengeMode = source.StartChallengeMode
    end
  end
  do
    local source = host.C_ChatBubbles
    if source then
      local target = {}
      api.chatBubbles = target
      target.getAllChatBubbles = source.GetAllChatBubbles
    end
  end
  do
    local source = host.C_ChatInfo
    if source then
      local target = {}
      api.chatInfo = target
      target.areOutgoingAddonChatMessagesRestricted = source.AreOutgoingAddonChatMessagesRestricted
      target.canPlayerSpeakLanguage = source.CanPlayerSpeakLanguage
      target.cancelEmote = source.CancelEmote
      target.dropCautionaryChatMessage = source.DropCautionaryChatMessage
      target.getChannelInfoFromIdentifier = source.GetChannelInfoFromIdentifier
      target.getChannelRosterInfo = source.GetChannelRosterInfo
      target.getChannelRuleset = source.GetChannelRuleset
      target.getChannelRulesetForChannelID = source.GetChannelRulesetForChannelID
      target.getChannelShortcut = source.GetChannelShortcut
      target.getChannelShortcutForChannelID = source.GetChannelShortcutForChannelID
      target.getChatLineSenderGUID = source.GetChatLineSenderGUID
      target.getChatLineSenderName = source.GetChatLineSenderName
      target.getChatLineText = source.GetChatLineText
      target.getChatTypeName = source.GetChatTypeName
      target.getClubStreamIDs = source.GetClubStreamIDs
      target.getColorForChatType = source.GetColorForChatType
      target.getGeneralChannelID = source.GetGeneralChannelID
      target.getGeneralChannelLocalID = source.GetGeneralChannelLocalID
      target.getMentorChannelID = source.GetMentorChannelID
      target.getNumActiveChannels = source.GetNumActiveChannels
      target.getNumReservedChatWindows = source.GetNumReservedChatWindows
      target.getRegisteredAddonMessagePrefixes = source.GetRegisteredAddonMessagePrefixes
      target.inChatMessagingLockdown = source.InChatMessagingLockdown
      target.isAddonMessagePrefixRegistered = source.IsAddonMessagePrefixRegistered
      target.isChannelRegional = source.IsChannelRegional
      target.isChannelRegionalForChannelID = source.IsChannelRegionalForChannelID
      target.isChatLineCensored = source.IsChatLineCensored
      target.isLoggingChat = source.IsLoggingChat
      target.isLoggingCombat = source.IsLoggingCombat
      target.isPartyChannelType = source.IsPartyChannelType
      target.isRegionalServiceAvailable = source.IsRegionalServiceAvailable
      target.isTimerunningPlayer = source.IsTimerunningPlayer
      target.isValidChatLine = source.IsValidChatLine
      target.isValidCombatFilterName = source.IsValidCombatFilterName
      target.performEmote = source.PerformEmote
      target.registerAddonMessagePrefix = source.RegisterAddonMessagePrefix
      target.replaceIconAndGroupExpressions = source.ReplaceIconAndGroupExpressions
      target.requestCanLocalWhisperTarget = source.RequestCanLocalWhisperTarget
      target.resetDefaultZoneChannels = source.ResetDefaultZoneChannels
      target.sendAddonMessage = source.SendAddonMessage
      target.sendAddonMessageLogged = source.SendAddonMessageLogged
      target.sendCautionaryChatMessage = source.SendCautionaryChatMessage
      target.sendChatMessage = source.SendChatMessage
      target.swapChatChannelsByChannelIndex = source.SwapChatChannelsByChannelIndex
      target.uncensorChatLine = source.UncensorChatLine
    end
  end
  do
    local source = host.C_ChromieTime
    if source then
      local target = {}
      api.chromieTime = target
      target.closeUI = source.CloseUI
      target.getChromieTimeExpansionOption = source.GetChromieTimeExpansionOption
      target.getChromieTimeExpansionOptions = source.GetChromieTimeExpansionOptions
      target.selectChromieTimeOption = source.SelectChromieTimeOption
    end
  end
  do
    local target = {}
    api.cinematic = target
    target.finished = host.CinematicFinished
    target.started = host.CinematicStarted
    target.getCurrentCinematicSummary = host.GetCurrentCinematicSummary
    target.inCinematic = host.InCinematic
    target.mouseOverrideCinematicDisable = host.MouseOverrideCinematicDisable
    target.openingCinematic = host.OpeningCinematic
    target.stopCinematic = host.StopCinematic
  end
  do
    local source = host.C_CinematicList
    if source then
      local target = {}
      api.cinematicList = target
      target.getUICinematicList = source.GetUICinematicList
    end
  end
  do
    local source = host.C_ClassColor
    if source then
      local target = {}
      api.classColor = target
      target.getClassColor = source.GetClassColor
    end
  end
  do
    local source = host.C_ClassTalents
    if source then
      local target = {}
      api.classTalents = target
      target.canChangeTalents = source.CanChangeTalents
      target.canCreateNewConfig = source.CanCreateNewConfig
      target.canEditTalents = source.CanEditTalents
      target.commitConfig = source.CommitConfig
      target.deleteConfig = source.DeleteConfig
      target.getActiveConfigID = source.GetActiveConfigID
      target.getActiveHeroTalentSpec = source.GetActiveHeroTalentSpec
      target.getConfigIDsBySpecID = source.GetConfigIDsBySpecID
      target.getHasStarterBuild = source.GetHasStarterBuild
      target.getHeroTalentSpecsForClassSpec = source.GetHeroTalentSpecsForClassSpec
      target.getLastSelectedSavedConfigID = source.GetLastSelectedSavedConfigID
      target.getNextStarterBuildPurchase = source.GetNextStarterBuildPurchase
      target.getStarterBuildActive = source.GetStarterBuildActive
      target.getTraitTreeForSpec = source.GetTraitTreeForSpec
      target.hasUnspentHeroTalentPoints = source.HasUnspentHeroTalentPoints
      target.hasUnspentTalentPoints = source.HasUnspentTalentPoints
      target.importLoadout = source.ImportLoadout
      target.initializeViewLoadout = source.InitializeViewLoadout
      target.isConfigPopulated = source.IsConfigPopulated
      target.loadConfig = source.LoadConfig
      target.renameConfig = source.RenameConfig
      target.requestNewConfig = source.RequestNewConfig
      target.saveConfig = source.SaveConfig
      target.setStarterBuildActive = source.SetStarterBuildActive
      target.setUsesSharedActionBars = source.SetUsesSharedActionBars
      target.switchToLoadoutByIndex = source.SwitchToLoadoutByIndex
      target.switchToLoadoutByName = source.SwitchToLoadoutByName
      target.switchToSpecializationByIndex = source.SwitchToSpecializationByIndex
      target.switchToSpecializationByName = source.SwitchToSpecializationByName
      target.updateLastSelectedSavedConfigID = source.UpdateLastSelectedSavedConfigID
      target.viewLoadout = source.ViewLoadout
    end
  end
  do
    local source = host.C_ClassTrial
    if source then
      local target = {}
      api.classTrial = target
    end
  end
  do
    local source = host.C_ClickBindings
    if source then
      local target = {}
      api.clickBindings = target
      target.canSpellBeClickBound = source.CanSpellBeClickBound
      target.executeBinding = source.ExecuteBinding
      target.getBindingType = source.GetBindingType
      target.getEffectiveInteractionButton = source.GetEffectiveInteractionButton
      target.getProfileInfo = source.GetProfileInfo
      target.getTutorialShown = source.GetTutorialShown
      target.resetCurrentProfile = source.ResetCurrentProfile
      target.setProfileByInfo = source.SetProfileByInfo
      target.setTutorialShown = source.SetTutorialShown
    end
  end
  do
    local target = {}
    api.client = target
    target.flashClientIcon = host.FlashClientIcon
    target.getBillingTimeRested = host.GetBillingTimeRested
    target.getFileIDFromPath = host.GetFileIDFromPath
    target.getFramerate = host.GetFramerate
    target.isCpuBound = host.IsCpuBound
    target.reportBug = host.ReportBug
    target.reportSuggestion = host.ReportSuggestion
    target.restartGx = host.RestartGx
    target.screenshot = host.Screenshot
    target.updateWindow = host.UpdateWindow
  end
  do
    local source = host.C_ClientScene
    if source then
      local target = {}
      api.clientScene = target
      target.isSceneTypeActive = source.IsSceneTypeActive
    end
  end
  do
    local source = host.C_Club
    if source then
      local target = {}
      api.club = target
      target.acceptInvitation = source.AcceptInvitation
      target.addClubStreamChatChannel = source.AddClubStreamChatChannel
      target.advanceStreamViewMarker = source.AdvanceStreamViewMarker
      target.areMembersReady = source.AreMembersReady
      target.assignMemberRole = source.AssignMemberRole
      target.canResolvePlayerLocationFromClubMessageData =
        source.CanResolvePlayerLocationFromClubMessageData
      target.clearAutoAdvanceStreamViewMarker = source.ClearAutoAdvanceStreamViewMarker
      target.clearClubPresenceSubscription = source.ClearClubPresenceSubscription
      target.compareBattleNetDisplayName = source.CompareBattleNetDisplayName
      target.createClub = source.CreateClub
      target.createStream = source.CreateStream
      target.createTicket = source.CreateTicket
      target.declineInvitation = source.DeclineInvitation
      target.destroyClub = source.DestroyClub
      target.destroyMessage = source.DestroyMessage
      target.destroyStream = source.DestroyStream
      target.destroyTicket = source.DestroyTicket
      target.doesAnyCommunityHaveUnreadMessages = source.DoesAnyCommunityHaveUnreadMessages
      target.doesCommunityHaveMembersOfTheOppositeFaction =
        source.DoesCommunityHaveMembersOfTheOppositeFaction
      target.editClub = source.EditClub
      target.editMessage = source.EditMessage
      target.editStream = source.EditStream
      target.flush = source.Flush
      target.focusCommunityStreams = source.FocusCommunityStreams
      target.focusMembers = source.FocusMembers
      target.focusStream = source.FocusStream
      target.getAssignableRoles = source.GetAssignableRoles
      target.getAvatarIdList = source.GetAvatarIdList
      target.getClubCapacity = source.GetClubCapacity
      target.getClubInfo = source.GetClubInfo
      target.getClubLimits = source.GetClubLimits
      target.getClubMembers = source.GetClubMembers
      target.getClubPrivileges = source.GetClubPrivileges
      target.getClubStreamNotificationSettings = source.GetClubStreamNotificationSettings
      target.getCommunityNameResultText = source.GetCommunityNameResultText
      target.getGuildClubId = source.GetGuildClubId
      target.getInfoFromLastCommunityChatLine = source.GetInfoFromLastCommunityChatLine
      target.getInvitationCandidates = source.GetInvitationCandidates
      target.getInvitationInfo = source.GetInvitationInfo
      target.getInvitationsForClub = source.GetInvitationsForClub
      target.getInvitationsForSelf = source.GetInvitationsForSelf
      target.getLastTicketResponse = source.GetLastTicketResponse
      target.getMemberInfo = source.GetMemberInfo
      target.getMemberInfoForSelf = source.GetMemberInfoForSelf
      target.getMessageInfo = source.GetMessageInfo
      target.getMessageRanges = source.GetMessageRanges
      target.getMessagesBefore = source.GetMessagesBefore
      target.getMessagesInRange = source.GetMessagesInRange
      target.getStreamInfo = source.GetStreamInfo
      target.getStreamViewMarker = source.GetStreamViewMarker
      target.getStreams = source.GetStreams
      target.getSubscribedClubs = source.GetSubscribedClubs
      target.getTickets = source.GetTickets
      target.isAccountMuted = source.IsAccountMuted
      target.isBeginningOfStream = source.IsBeginningOfStream
      target.isEnabled = source.IsEnabled
      target.isRestricted = source.IsRestricted
      target.isSubscribedToStream = source.IsSubscribedToStream
      target.kickMember = source.KickMember
      target.leaveClub = source.LeaveClub
      target.redeemTicket = source.RedeemTicket
      target.requestInvitationsForClub = source.RequestInvitationsForClub
      target.requestMoreMessagesBefore = source.RequestMoreMessagesBefore
      target.requestTicket = source.RequestTicket
      target.requestTickets = source.RequestTickets
      target.revokeInvitation = source.RevokeInvitation
      target.sendBattleTagFriendRequest = source.SendBattleTagFriendRequest
      target.sendCharacterInvitation = source.SendCharacterInvitation
      target.sendInvitation = source.SendInvitation
      target.sendMessage = source.SendMessage
      target.sendTitleFriendRequest = source.SendTitleFriendRequest
      target.setAutoAdvanceStreamViewMarker = source.SetAutoAdvanceStreamViewMarker
      target.setAvatarTexture = source.SetAvatarTexture
      target.setClubMemberNote = source.SetClubMemberNote
      target.setClubPresenceSubscription = source.SetClubPresenceSubscription
      target.setClubStreamNotificationSettings = source.SetClubStreamNotificationSettings
      target.setCommunityID = source.SetCommunityID
      target.setFavorite = source.SetFavorite
      target.setSocialQueueingEnabled = source.SetSocialQueueingEnabled
      target.shouldAllowClubType = source.ShouldAllowClubType
      target.unfocusAllStreams = source.UnfocusAllStreams
      target.unfocusMembers = source.UnfocusMembers
      target.unfocusStream = source.UnfocusStream
      target.validateText = source.ValidateText
    end
  end
  do
    local source = host.C_ClubFinder
    if source then
      local target = {}
      api.clubFinder = target
      target.applicantAcceptClubInvite = source.ApplicantAcceptClubInvite
      target.applicantDeclineClubInvite = source.ApplicantDeclineClubInvite
      target.cancelMembershipRequest = source.CancelMembershipRequest
      target.checkAllPlayerApplicantSettings = source.CheckAllPlayerApplicantSettings
      target.clearAllFinderCache = source.ClearAllFinderCache
      target.clearClubApplicantsCache = source.ClearClubApplicantsCache
      target.clearClubFinderPostingsCache = source.ClearClubFinderPostingsCache
      target.doesPlayerBelongToClubFromClubGUID = source.DoesPlayerBelongToClubFromClubGUID
      target.getClubFinderDisableReason = source.GetClubFinderDisableReason
      target.getClubRecruitmentSettings = source.GetClubRecruitmentSettings
      target.getClubTypeFromFinderGUID = source.GetClubTypeFromFinderGUID
      target.getFocusIndexFromFlag = source.GetFocusIndexFromFlag
      target.getPlayerApplicantLocaleFlags = source.GetPlayerApplicantLocaleFlags
      target.getPlayerApplicantSettings = source.GetPlayerApplicantSettings
      target.getPlayerClubApplicationStatus = source.GetPlayerClubApplicationStatus
      target.getPlayerSettingsFocusFlagsSelectedCount =
        source.GetPlayerSettingsFocusFlagsSelectedCount
      target.getPostingIDFromClubFinderGUID = source.GetPostingIDFromClubFinderGUID
      target.getRecruitingClubInfoFromClubID = source.GetRecruitingClubInfoFromClubID
      target.getRecruitingClubInfoFromFinderGUID = source.GetRecruitingClubInfoFromFinderGUID
      target.getStatusOfPostingFromClubId = source.GetStatusOfPostingFromClubId
      target.getTotalMatchingCommunityListSize = source.GetTotalMatchingCommunityListSize
      target.getTotalMatchingGuildListSize = source.GetTotalMatchingGuildListSize
      target.hasAlreadyAppliedToLinkedPosting = source.HasAlreadyAppliedToLinkedPosting
      target.hasPostingBeenDelisted = source.HasPostingBeenDelisted
      target.isCommunityFinderEnabled = source.IsCommunityFinderEnabled
      target.isEnabled = source.IsEnabled
      target.isListingEnabledFromFlags = source.IsListingEnabledFromFlags
      target.isPostingBanned = source.IsPostingBanned
      target.isValidSearchString = source.IsValidSearchString
      target.lookupClubPostingFromClubFinderGUID = source.LookupClubPostingFromClubFinderGUID
      target.playerGetClubInvitationList = source.PlayerGetClubInvitationList
      target.playerRequestPendingClubsList = source.PlayerRequestPendingClubsList
      target.playerReturnPendingCommunitiesList = source.PlayerReturnPendingCommunitiesList
      target.playerReturnPendingGuildsList = source.PlayerReturnPendingGuildsList
      target.postClub = source.PostClub
      target.requestApplicantList = source.RequestApplicantList
      target.requestClubsList = source.RequestClubsList
      target.requestMembershipToClub = source.RequestMembershipToClub
      target.requestNextCommunityPage = source.RequestNextCommunityPage
      target.requestNextGuildPage = source.RequestNextGuildPage
      target.requestPostingInformationFromClubId = source.RequestPostingInformationFromClubId
      target.requestSubscribedClubPostingIDs = source.RequestSubscribedClubPostingIDs
      target.resetClubPostingMapCache = source.ResetClubPostingMapCache
      target.respondToApplicant = source.RespondToApplicant
      target.returnClubApplicantList = source.ReturnClubApplicantList
      target.returnMatchingCommunityList = source.ReturnMatchingCommunityList
      target.returnMatchingGuildList = source.ReturnMatchingGuildList
      target.returnPendingClubApplicantList = source.ReturnPendingClubApplicantList
      target.sendChatWhisper = source.SendChatWhisper
      target.setAllRecruitmentSettings = source.SetAllRecruitmentSettings
      target.setPlayerApplicantLocaleFlags = source.SetPlayerApplicantLocaleFlags
      target.setPlayerApplicantSettings = source.SetPlayerApplicantSettings
      target.setRecruitmentLocale = source.SetRecruitmentLocale
      target.setRecruitmentSettings = source.SetRecruitmentSettings
      target.shouldShowClubFinder = source.ShouldShowClubFinder
    end
  end
  do
    local source = host.C_ColorOverrides
    if source then
      local target = {}
      api.colorOverrides = target
      target.clearColorOverrides = source.ClearColorOverrides
      target.getColorForQuality = source.GetColorForQuality
      target.getColorOverrideInfo = source.GetColorOverrideInfo
      target.getDefaultColorForQuality = source.GetDefaultColorForQuality
      target.removeColorOverride = source.RemoveColorOverride
      target.setColorOverride = source.SetColorOverride
    end
  end
  do
    local source = host.C_ColorUtil
    if source then
      local target = {}
      api.colorUtil = target
      target.convertHSLToHSV = source.ConvertHSLToHSV
      target.convertHSVToHSL = source.ConvertHSVToHSL
      target.convertHSVToRGB = source.ConvertHSVToRGB
      target.convertRGBToHSV = source.ConvertRGBToHSV
      target.generateTextColorCode = source.GenerateTextColorCode
      target.wrapTextInColor = source.WrapTextInColor
      target.wrapTextInColorCode = source.WrapTextInColorCode
    end
  end
  do
    local source = host.C_CombatAudioAlert
    if source then
      local target = {}
      api.combatAudioAlert = target
      target.addToKnownTargetingList = source.AddToKnownTargetingList
      target.getCategoryVoice = source.GetCategoryVoice
      target.getCategoryVolume = source.GetCategoryVolume
      target.getFormatSetting = source.GetFormatSetting
      target.getSpeakerSpeed = source.GetSpeakerSpeed
      target.getSpecSetting = source.GetSpecSetting
      target.getThrottle = source.GetThrottle
      target.isEnabled = source.IsEnabled
      target.removeFromKnownTargetingList = source.RemoveFromKnownTargetingList
      target.setCategoryVoice = source.SetCategoryVoice
      target.setCategoryVolume = source.SetCategoryVolume
      target.setFormatSetting = source.SetFormatSetting
      target.setSpeakerSpeed = source.SetSpeakerSpeed
      target.setSpecSetting = source.SetSpecSetting
      target.setThrottle = source.SetThrottle
      target.speakText = source.SpeakText
    end
  end
  do
    local source = host.C_CombatLog
    if source then
      local target = {}
      api.combatLog = target
      target.applyFilterSettings = source.ApplyFilterSettings
      target.areFilteredEventsEnabled = source.AreFilteredEventsEnabled
      target.clearEntries = source.ClearEntries
      target.doesObjectMatchFilter = source.DoesObjectMatchFilter
      target.getEntryRetentionTime = source.GetEntryRetentionTime
      target.getMessageLimit = source.GetMessageLimit
      target.isCombatLogRestricted = source.IsCombatLogRestricted
      target.refilterEntries = source.RefilterEntries
      target.setEntryRetentionTime = source.SetEntryRetentionTime
      target.setFilteredEventsEnabled = source.SetFilteredEventsEnabled
      target.setMessageLimit = source.SetMessageLimit
    end
  end
  do
    local source = host.C_CombatLogInternal
    if source then
      local target = {}
      api.combatLogInternal = target
      target.getCurrentEventInfo = source.GetCurrentEventInfo
    end
  end
  do
    local source = host.C_CombatLogSecure
    if source then
      local target = {}
      api.combatLogSecure = target
      target.addEventFilter = source.AddEventFilter
      target.clearEventFilters = source.ClearEventFilters
      target.createCombatLogMessage = source.CreateCombatLogMessage
      target.getCurrentEntryInfo = source.GetCurrentEntryInfo
      target.getCurrentEventInfo = source.GetCurrentEventInfo
      target.getEntryCount = source.GetEntryCount
      target.seekToNewestEntry = source.SeekToNewestEntry
      target.seekToPreviousEntry = source.SeekToPreviousEntry
      target.shouldShowCurrentEntry = source.ShouldShowCurrentEntry
    end
  end
  do
    local source = host.C_CombatText
    if source then
      local target = {}
      api.combatText = target
      target.getActiveUnit = source.GetActiveUnit
      target.getCurrentEventInfo = source.GetCurrentEventInfo
      target.setActiveUnit = source.SetActiveUnit
    end
  end
  do
    local source = host.C_Commentator
    if source then
      local target = {}
      api.commentator = target
      target.addPlayerOverrideName = source.AddPlayerOverrideName
      target.addTrackedDefensiveAuras = source.AddTrackedDefensiveAuras
      target.addTrackedOffensiveAuras = source.AddTrackedOffensiveAuras
      target.areTeamsSwapped = source.AreTeamsSwapped
      target.assignPlayerToTeam = source.AssignPlayerToTeam
      target.assignPlayersToTeam = source.AssignPlayersToTeam
      target.assignPlayersToTeamInCurrentInstance = source.AssignPlayersToTeamInCurrentInstance
      target.canUseCommentatorCheats = source.CanUseCommentatorCheats
      target.clearCameraTarget = source.ClearCameraTarget
      target.clearFollowTarget = source.ClearFollowTarget
      target.clearLookAtTarget = source.ClearLookAtTarget
      target.enterInstance = source.EnterInstance
      target.exitInstance = source.ExitInstance
      target.findSpectatedUnit = source.FindSpectatedUnit
      target.findTeamNameInCurrentInstance = source.FindTeamNameInCurrentInstance
      target.findTeamNameInDirectory = source.FindTeamNameInDirectory
      target.flushCommentatorHistory = source.FlushCommentatorHistory
      target.followPlayer = source.FollowPlayer
      target.followUnit = source.FollowUnit
      target.forceFollowTransition = source.ForceFollowTransition
      target.getAdditionalCameraWeight = source.GetAdditionalCameraWeight
      target.getAdditionalCameraWeightByToken = source.GetAdditionalCameraWeightByToken
      target.getAllPlayerOverrideNames = source.GetAllPlayerOverrideNames
      target.getCamera = source.GetCamera
      target.getCameraCollision = source.GetCameraCollision
      target.getCameraPosition = source.GetCameraPosition
      target.getCombatEventInfo = source.GetCombatEventInfo
      target.getCommentatorHistory = source.GetCommentatorHistory
      target.getCommentatorMatchDataState = source.GetCommentatorMatchDataState
      target.getCurrentMapID = source.GetCurrentMapID
      target.getDampeningPercent = source.GetDampeningPercent
      target.getDistanceBeforeForcedHorizontalConvergence =
        source.GetDistanceBeforeForcedHorizontalConvergence
      target.getDurationToForceHorizontalConvergence =
        source.GetDurationToForceHorizontalConvergence
      target.getExcludeDistance = source.GetExcludeDistance
      target.getHardlockWeight = source.GetHardlockWeight
      target.getHorizontalAngleThresholdToSmooth = source.GetHorizontalAngleThresholdToSmooth
      target.getIndirectSpellID = source.GetIndirectSpellID
      target.getInstanceInfo = source.GetInstanceInfo
      target.getLookAtLerpAmount = source.GetLookAtLerpAmount
      target.getMapInfo = source.GetMapInfo
      target.getMatchDuration = source.GetMatchDuration
      target.getMaxNumPlayersPerTeam = source.GetMaxNumPlayersPerTeam
      target.getMaxNumTeams = source.GetMaxNumTeams
      target.getMode = source.GetMode
      target.getMsToHoldForHorizontalMovement = source.GetMsToHoldForHorizontalMovement
      target.getMsToHoldForVerticalMovement = source.GetMsToHoldForVerticalMovement
      target.getMsToSmoothHorizontalChange = source.GetMsToSmoothHorizontalChange
      target.getMsToSmoothVerticalChange = source.GetMsToSmoothVerticalChange
      target.getNumMaps = source.GetNumMaps
      target.getNumPlayers = source.GetNumPlayers
      target.getOrCreateSeries = source.GetOrCreateSeries
      target.getPlayerAuraInfo = source.GetPlayerAuraInfo
      target.getPlayerAuraInfoByUnit = source.GetPlayerAuraInfoByUnit
      target.getPlayerCooldownInfo = source.GetPlayerCooldownInfo
      target.getPlayerCooldownInfoByUnit = source.GetPlayerCooldownInfoByUnit
      target.getPlayerCrowdControlInfo = source.GetPlayerCrowdControlInfo
      target.getPlayerCrowdControlInfoByUnit = source.GetPlayerCrowdControlInfoByUnit
      target.getPlayerData = source.GetPlayerData
      target.getPlayerFlagInfo = source.GetPlayerFlagInfo
      target.getPlayerFlagInfoByUnit = source.GetPlayerFlagInfoByUnit
      target.getPlayerItemCooldownInfo = source.GetPlayerItemCooldownInfo
      target.getPlayerItemCooldownInfoByUnit = source.GetPlayerItemCooldownInfoByUnit
      target.getPlayerOverrideName = source.GetPlayerOverrideName
      target.getPlayerSpellCharges = source.GetPlayerSpellCharges
      target.getPlayerSpellChargesByUnit = source.GetPlayerSpellChargesByUnit
      target.getPositionLerpAmount = source.GetPositionLerpAmount
      target.getSmoothFollowTransitioning = source.GetSmoothFollowTransitioning
      target.getSoftlockWeight = source.GetSoftlockWeight
      target.getSpeedFactor = source.GetSpeedFactor
      target.getStartLocation = source.GetStartLocation
      target.getTeamColor = source.GetTeamColor
      target.getTeamColorByUnit = source.GetTeamColorByUnit
      target.getTimeLeftInMatch = source.GetTimeLeftInMatch
      target.getTrackedSpellID = source.GetTrackedSpellID
      target.getTrackedSpells = source.GetTrackedSpells
      target.getTrackedSpellsByUnit = source.GetTrackedSpellsByUnit
      target.getUnitData = source.GetUnitData
      target.getWargameInfo = source.GetWargameInfo
      target.hasTrackedAuras = source.HasTrackedAuras
      target.isSmartCameraLocked = source.IsSmartCameraLocked
      target.isSpectating = source.IsSpectating
      target.isTrackedDefensiveAura = source.IsTrackedDefensiveAura
      target.isTrackedOffensiveAura = source.IsTrackedOffensiveAura
      target.isTrackedSpell = source.IsTrackedSpell
      target.isTrackedSpellByUnit = source.IsTrackedSpellByUnit
      target.isUsingSmartCamera = source.IsUsingSmartCamera
      target.lookAtPlayer = source.LookAtPlayer
      target.removeAllOverrideNames = source.RemoveAllOverrideNames
      target.removePlayerOverrideName = source.RemovePlayerOverrideName
      target.requestPlayerCooldownInfo = source.RequestPlayerCooldownInfo
      target.resetFoVTarget = source.ResetFoVTarget
      target.resetSeriesScores = source.ResetSeriesScores
      target.resetSettings = source.ResetSettings
      target.resetTrackedAuras = source.ResetTrackedAuras
      target.sendAddonMessage = source.SendAddonMessage
      target.sendAddonMessageLogged = source.SendAddonMessageLogged
      target.setAdditionalCameraWeight = source.SetAdditionalCameraWeight
      target.setAdditionalCameraWeightByToken = source.SetAdditionalCameraWeightByToken
      target.setBlocklistedAuras = source.SetBlocklistedAuras
      target.setBlocklistedCooldowns = source.SetBlocklistedCooldowns
      target.setBlocklistedItemCooldowns = source.SetBlocklistedItemCooldowns
      target.setCamera = source.SetCamera
      target.setCameraCollision = source.SetCameraCollision
      target.setCameraPosition = source.SetCameraPosition
      target.setCheatsEnabled = source.SetCheatsEnabled
      target.setCommentatorHistory = source.SetCommentatorHistory
      target.setDistanceBeforeForcedHorizontalConvergence =
        source.SetDistanceBeforeForcedHorizontalConvergence
      target.setDurationToForceHorizontalConvergence =
        source.SetDurationToForceHorizontalConvergence
      target.setExcludeDistance = source.SetExcludeDistance
      target.setFollowCameraSpeeds = source.SetFollowCameraSpeeds
      target.setHardlockWeight = source.SetHardlockWeight
      target.setHorizontalAngleThresholdToSmooth = source.SetHorizontalAngleThresholdToSmooth
      target.setLookAtLerpAmount = source.SetLookAtLerpAmount
      target.setMapAndInstanceIndex = source.SetMapAndInstanceIndex
      target.setMouseDisabled = source.SetMouseDisabled
      target.setMoveSpeed = source.SetMoveSpeed
      target.setMsToHoldForHorizontalMovement = source.SetMsToHoldForHorizontalMovement
      target.setMsToHoldForVerticalMovement = source.SetMsToHoldForVerticalMovement
      target.setMsToSmoothHorizontalChange = source.SetMsToSmoothHorizontalChange
      target.setMsToSmoothVerticalChange = source.SetMsToSmoothVerticalChange
      target.setPositionLerpAmount = source.SetPositionLerpAmount
      target.setRequestedDebuffCooldowns = source.SetRequestedDebuffCooldowns
      target.setRequestedDefensiveCooldowns = source.SetRequestedDefensiveCooldowns
      target.setRequestedItemCooldowns = source.SetRequestedItemCooldowns
      target.setRequestedOffensiveCooldowns = source.SetRequestedOffensiveCooldowns
      target.setSeriesScore = source.SetSeriesScore
      target.setSeriesScores = source.SetSeriesScores
      target.setSmartCameraLocked = source.SetSmartCameraLocked
      target.setSmoothFollowTransitioning = source.SetSmoothFollowTransitioning
      target.setSoftlockWeight = source.SetSoftlockWeight
      target.setSpeedFactor = source.SetSpeedFactor
      target.setTargetHeightOffset = source.SetTargetHeightOffset
      target.setUseSmartCamera = source.SetUseSmartCamera
      target.snapCameraLookAtPoint = source.SnapCameraLookAtPoint
      target.spellUsesItemCharges = source.SpellUsesItemCharges
      target.startWargame = source.StartWargame
      target.swapTeamSides = source.SwapTeamSides
      target.toggleCheats = source.ToggleCheats
      target.updateMapInfo = source.UpdateMapInfo
      target.updatePlayerInfo = source.UpdatePlayerInfo
      target.zoomIn = source.ZoomIn
      target.zoomInPosition = source.ZoomIn_Position
      target.zoomOut = source.ZoomOut
      target.zoomOutPosition = source.ZoomOut_Position
    end
  end
  do
    local source = host.C_CompactUnitFrames
    if source then
      local target = {}
      api.compactUnitFrames = target
    end
  end
  do
    local source = host.C_ConfigurationWarnings
    if source then
      local target = {}
      api.configurationWarnings = target
      target.getConfigurationWarningSeen = source.GetConfigurationWarningSeen
      target.getConfigurationWarningString = source.GetConfigurationWarningString
      target.getConfigurationWarnings = source.GetConfigurationWarnings
      target.setConfigurationWarningSeen = source.SetConfigurationWarningSeen
    end
  end
  do
    local target = {}
    api.connectionScript = target
    target.cancelLogout = host.CancelLogout
    target.forceLogout = host.ForceLogout
    target.forceQuit = host.ForceQuit
    target.getNativeRealmID = host.GetNativeRealmID
    target.getNetIpTypes = host.GetNetIpTypes
    target.getNetStats = host.GetNetStats
    target.getProtocolTypes = host.GetProtocolTypes
    target.getRealmID = host.GetRealmID
    target.getRealmName = host.GetRealmName
    target.isOnTournamentRealm = host.IsOnTournamentRealm
    target.logout = host.Logout
    target.quit = host.Quit
    target.selectedRealmName = host.SelectedRealmName
  end
  do
    local target = {}
    api.console = target
    target.calculateStringEditDistance = host.CalculateStringEditDistance
    target.echo = host.ConsoleEcho
    target.exec = host.ConsoleExec
    target.getAllCommands = host.ConsoleGetAllCommands
    target.getColorFromType = host.ConsoleGetColorFromType
    target.getFontHeight = host.ConsoleGetFontHeight
    target.isActive = host.ConsoleIsActive
    target.printAllMatchingCommands = host.ConsolePrintAllMatchingCommands
    target.setFontHeight = host.ConsoleSetFontHeight
    target.setConsoleKey = host.SetConsoleKey
  end
  do
    local source = host.C_ConsoleScriptCollection
    if source then
      local target = {}
      api.consoleScriptCollection = target
      target.getCollectionDataByID = source.GetCollectionDataByID
      target.getCollectionDataByTag = source.GetCollectionDataByTag
      target.getElements = source.GetElements
      target.getScriptData = source.GetScriptData
    end
  end
  do
    local source = host.C_Container
    if source then
      local target = {}
      api.container = target
      target.calculateTotalNumberOfFreeBagSlots = source.CalculateTotalNumberOfFreeBagSlots
      target.containerIDToInventoryID = source.ContainerIDToInventoryID
      target.containerRefundItemPurchase = source.ContainerRefundItemPurchase
      target.getBackpackAutosortDisabled = source.GetBackpackAutosortDisabled
      target.getBackpackSellJunkDisabled = source.GetBackpackSellJunkDisabled
      target.getBagName = source.GetBagName
      target.getBagSlotFlag = source.GetBagSlotFlag
      target.getBankAutosortDisabled = source.GetBankAutosortDisabled
      target.getContainerFreeSlots = source.GetContainerFreeSlots
      target.getContainerItemCooldown = source.GetContainerItemCooldown
      target.getContainerItemDurability = source.GetContainerItemDurability
      target.getContainerItemEquipmentSetInfo = source.GetContainerItemEquipmentSetInfo
      target.getContainerItemID = source.GetContainerItemID
      target.getContainerItemInfo = source.GetContainerItemInfo
      target.getContainerItemLink = source.GetContainerItemLink
      target.getContainerItemPurchaseCurrency = source.GetContainerItemPurchaseCurrency
      target.getContainerItemPurchaseInfo = source.GetContainerItemPurchaseInfo
      target.getContainerItemPurchaseItem = source.GetContainerItemPurchaseItem
      target.getContainerItemQuestInfo = source.GetContainerItemQuestInfo
      target.getContainerNumFreeSlots = source.GetContainerNumFreeSlots
      target.getContainerNumSlots = source.GetContainerNumSlots
      target.getInsertItemsLeftToRight = source.GetInsertItemsLeftToRight
      target.getItemCooldown = source.GetItemCooldown
      target.getMaxArenaCurrency = source.GetMaxArenaCurrency
      target.getSortBagsRightToLeft = source.GetSortBagsRightToLeft
      target.hasContainerItem = source.HasContainerItem
      target.isBattlePayItem = source.IsBattlePayItem
      target.isContainerFiltered = source.IsContainerFiltered
      target.pickupContainerItem = source.PickupContainerItem
      target.playerHasHearthstone = source.PlayerHasHearthstone
      target.setBackpackAutosortDisabled = source.SetBackpackAutosortDisabled
      target.setBackpackSellJunkDisabled = source.SetBackpackSellJunkDisabled
      target.setBagPortraitTexture = source.SetBagPortraitTexture
      target.setBagSlotFlag = source.SetBagSlotFlag
      target.setBankAutosortDisabled = source.SetBankAutosortDisabled
      target.setInsertItemsLeftToRight = source.SetInsertItemsLeftToRight
      target.setItemSearch = source.SetItemSearch
      target.setSortBagsRightToLeft = source.SetSortBagsRightToLeft
      target.showContainerSellCursor = source.ShowContainerSellCursor
      target.socketContainerItem = source.SocketContainerItem
      target.sortAccountBankBags = source.SortAccountBankBags
      target.sortBags = source.SortBags
      target.sortBank = source.SortBank
      target.sortBankBags = source.SortBankBags
      target.splitContainerItem = source.SplitContainerItem
      target.useContainerItem = source.UseContainerItem
      target.useHearthstone = source.UseHearthstone
    end
  end
  do
    local source = host.C_ContentTracking
    if source then
      local target = {}
      api.contentTracking = target
      target.getBestMapForTrackable = source.GetBestMapForTrackable
      target.getCollectableSourceTrackingEnabled = source.GetCollectableSourceTrackingEnabled
      target.getCollectableSourceTypes = source.GetCollectableSourceTypes
      target.getCurrentTrackingTarget = source.GetCurrentTrackingTarget
      target.getEncounterTrackingInfo = source.GetEncounterTrackingInfo
      target.getNextWaypointForTrackable = source.GetNextWaypointForTrackable
      target.getObjectiveText = source.GetObjectiveText
      target.getTitle = source.GetTitle
      target.getTrackablesOnMap = source.GetTrackablesOnMap
      target.getTrackedIDs = source.GetTrackedIDs
      target.getVendorTrackingInfo = source.GetVendorTrackingInfo
      target.getWaypointText = source.GetWaypointText
      target.isNavigable = source.IsNavigable
      target.isTrackable = source.IsTrackable
      target.isTracking = source.IsTracking
      target.startTracking = source.StartTracking
      target.stopTracking = source.StopTracking
      target.toggleTracking = source.ToggleTracking
    end
  end
  do
    local source = host.C_ContributionCollector
    if source then
      local target = {}
      api.contributionCollector = target
      target.close = source.Close
      target.contribute = source.Contribute
      target.getActive = source.GetActive
      target.getAtlases = source.GetAtlases
      target.getBuffs = source.GetBuffs
      target.getContributionAppearance = source.GetContributionAppearance
      target.getContributionCollectorsForMap = source.GetContributionCollectorsForMap
      target.getContributionResult = source.GetContributionResult
      target.getDescription = source.GetDescription
      target.getManagedContributionsForCreatureID = source.GetManagedContributionsForCreatureID
      target.getName = source.GetName
      target.getOrderIndex = source.GetOrderIndex
      target.getRequiredContributionCurrency = source.GetRequiredContributionCurrency
      target.getRequiredContributionItem = source.GetRequiredContributionItem
      target.getRewardQuestID = source.GetRewardQuestID
      target.getState = source.GetState
      target.hasPendingContribution = source.HasPendingContribution
      target.isAwaitingRewardQuestData = source.IsAwaitingRewardQuestData
    end
  end
  do
    local source = host.C_CooldownViewer
    if source then
      local target = {}
      api.cooldownViewer = target
      target.getCooldownViewerCategorySet = source.GetCooldownViewerCategorySet
      target.getCooldownViewerCooldownInfo = source.GetCooldownViewerCooldownInfo
      target.getGroupBuffItems = source.GetGroupBuffItems
      target.getLayoutData = source.GetLayoutData
      target.getValidAlertTypes = source.GetValidAlertTypes
      target.isCooldownViewerAvailable = source.IsCooldownViewerAvailable
      target.setLayoutData = source.SetLayoutData
    end
  end
  do
    local source = host.C_CovenantCallings
    if source then
      local target = {}
      api.covenantCallings = target
      target.areCallingsUnlocked = source.AreCallingsUnlocked
      target.requestCallings = source.RequestCallings
    end
  end
  do
    local source = host.C_CovenantPreview
    if source then
      local target = {}
      api.covenantPreview = target
      target.closeFromUI = source.CloseFromUI
      target.getCovenantInfoForPlayerChoiceResponseID =
        source.GetCovenantInfoForPlayerChoiceResponseID
    end
  end
  do
    local source = host.C_CovenantSanctumUI
    if source then
      local target = {}
      api.covenantSanctumUI = target
      target.canAccessReservoir = source.CanAccessReservoir
      target.canDepositAnima = source.CanDepositAnima
      target.depositAnima = source.DepositAnima
      target.endInteraction = source.EndInteraction
      target.getAnimaInfo = source.GetAnimaInfo
      target.getCurrentTalentTreeID = source.GetCurrentTalentTreeID
      target.getFeatures = source.GetFeatures
      target.getRenownLevel = source.GetRenownLevel
      target.getRenownLevels = source.GetRenownLevels
      target.getRenownRewardsForLevel = source.GetRenownRewardsForLevel
      target.getSanctumType = source.GetSanctumType
      target.getSoulCurrencies = source.GetSoulCurrencies
      target.hasMaximumRenown = source.HasMaximumRenown
      target.isPlayerInRenownCatchUpMode = source.IsPlayerInRenownCatchUpMode
      target.isWeeklyRenownCapped = source.IsWeeklyRenownCapped
      target.requestCatchUpState = source.RequestCatchUpState
    end
  end
  do
    local source = host.C_Covenants
    if source then
      local target = {}
      api.covenants = target
      target.getActiveCovenantID = source.GetActiveCovenantID
      target.getCovenantData = source.GetCovenantData
      target.getCovenantIDs = source.GetCovenantIDs
    end
  end
  do
    local source = host.C_CraftingOrders
    if source then
      local target = {}
      api.craftingOrders = target
      target.areOrderNotesDisabled = source.AreOrderNotesDisabled
      target.calculateCraftingOrderPostingFee = source.CalculateCraftingOrderPostingFee
      target.canOrderSkillAbility = source.CanOrderSkillAbility
      target.cancelOrder = source.CancelOrder
      target.claimOrder = source.ClaimOrder
      target.closeCrafterCraftingOrders = source.CloseCrafterCraftingOrders
      target.closeCustomerCraftingOrders = source.CloseCustomerCraftingOrders
      target.fulfillOrder = source.FulfillOrder
      target.getClaimedOrder = source.GetClaimedOrder
      target.getCrafterBuckets = source.GetCrafterBuckets
      target.getCrafterOrders = source.GetCrafterOrders
      target.getCraftingOrderTime = source.GetCraftingOrderTime
      target.getCustomerCategories = source.GetCustomerCategories
      target.getCustomerOptions = source.GetCustomerOptions
      target.getCustomerOrders = source.GetCustomerOrders
      target.getDefaultOrdersSkillLine = source.GetDefaultOrdersSkillLine
      target.getMyOrders = source.GetMyOrders
      target.getNumFavoriteCustomerOptions = source.GetNumFavoriteCustomerOptions
      target.getOrderClaimInfo = source.GetOrderClaimInfo
      target.getPersonalOrdersInfo = source.GetPersonalOrdersInfo
      target.hasFavoriteCustomerOptions = source.HasFavoriteCustomerOptions
      target.isCustomerOptionFavorited = source.IsCustomerOptionFavorited
      target.listMyOrders = source.ListMyOrders
      target.openCrafterCraftingOrders = source.OpenCrafterCraftingOrders
      target.openCustomerCraftingOrders = source.OpenCustomerCraftingOrders
      target.orderCanBeRecrafted = source.OrderCanBeRecrafted
      target.parseCustomerOptions = source.ParseCustomerOptions
      target.placeNewOrder = source.PlaceNewOrder
      target.rejectOrder = source.RejectOrder
      target.releaseOrder = source.ReleaseOrder
      target.requestCrafterOrders = source.RequestCrafterOrders
      target.requestCustomerOrders = source.RequestCustomerOrders
      target.setCustomerOptionFavorited = source.SetCustomerOptionFavorited
      target.shouldShowCraftingOrderTab = source.ShouldShowCraftingOrderTab
      target.skillLineHasOrders = source.SkillLineHasOrders
      target.updateIgnoreList = source.UpdateIgnoreList
    end
  end
  do
    local source = host.C_CreatureInfo
    if source then
      local target = {}
      api.creatureInfo = target
      target.getClassInfo = source.GetClassInfo
      target.getCreatureFamilyIDs = source.GetCreatureFamilyIDs
      target.getCreatureFamilyInfo = source.GetCreatureFamilyInfo
      target.getCreatureID = source.GetCreatureID
      target.getCreatureTypeIDs = source.GetCreatureTypeIDs
      target.getCreatureTypeInfo = source.GetCreatureTypeInfo
      target.getFactionInfo = source.GetFactionInfo
      target.getRaceInfo = source.GetRaceInfo
    end
  end
  do
    local source = host.C_CurrencyInfo
    if source then
      local target = {}
      api.currencyInfo = target
      target.canTransferCurrency = source.CanTransferCurrency
      target.doesCurrentFilterRequireAccountCurrencyData =
        source.DoesCurrentFilterRequireAccountCurrencyData
      target.doesWarModeBonusApply = source.DoesWarModeBonusApply
      target.expandCurrencyList = source.ExpandCurrencyList
      target.fetchCurrencyDataFromAccountCharacters = source.FetchCurrencyDataFromAccountCharacters
      target.fetchCurrencyTransferTransactions = source.FetchCurrencyTransferTransactions
      target.getAzeriteCurrencyID = source.GetAzeriteCurrencyID
      target.getBackpackCurrencyInfo = source.GetBackpackCurrencyInfo
      target.getBasicCurrencyInfo = source.GetBasicCurrencyInfo
      target.getCoinIcon = source.GetCoinIcon
      target.getCoinText = source.GetCoinText
      target.getCoinTextureString = source.GetCoinTextureString
      target.getCostToTransferCurrency = source.GetCostToTransferCurrency
      target.getCurrencyContainerInfo = source.GetCurrencyContainerInfo
      target.getCurrencyDescription = source.GetCurrencyDescription
      target.getCurrencyFilter = source.GetCurrencyFilter
      target.getCurrencyIDFromLink = source.GetCurrencyIDFromLink
      target.getCurrencyInfo = source.GetCurrencyInfo
      target.getCurrencyInfoFromLink = source.GetCurrencyInfoFromLink
      target.getCurrencyLink = source.GetCurrencyLink
      target.getCurrencyListInfo = source.GetCurrencyListInfo
      target.getCurrencyListLink = source.GetCurrencyListLink
      target.getCurrencyListSize = source.GetCurrencyListSize
      target.getDragonIslesSuppliesCurrencyID = source.GetDragonIslesSuppliesCurrencyID
      target.getFactionGrantedByCurrency = source.GetFactionGrantedByCurrency
      target.getMaxTransferableAmountFromQuantity = source.GetMaxTransferableAmountFromQuantity
      target.getPlayerCurrencyCategoryInfo = source.GetPlayerCurrencyCategoryInfo
      target.getWarResourcesCurrencyID = source.GetWarResourcesCurrencyID
      target.isAccountCharacterCurrencyDataReady = source.IsAccountCharacterCurrencyDataReady
      target.isAccountTransferableCurrency = source.IsAccountTransferableCurrency
      target.isAccountWideCurrency = source.IsAccountWideCurrency
      target.isCurrencyContainer = source.IsCurrencyContainer
      target.isCurrencyTransferInProgress = source.IsCurrencyTransferInProgress
      target.isCurrencyTransferTransactionDataReady = source.IsCurrencyTransferTransactionDataReady
      target.pickupCurrency = source.PickupCurrency
      target.playerHasMaxQuantity = source.PlayerHasMaxQuantity
      target.playerHasMaxWeeklyQuantity = source.PlayerHasMaxWeeklyQuantity
      target.requestCurrencyDataForAccountCharacters =
        source.RequestCurrencyDataForAccountCharacters
      target.requestCurrencyFromAccountCharacter = source.RequestCurrencyFromAccountCharacter
      target.setCurrencyBackpack = source.SetCurrencyBackpack
      target.setCurrencyBackpackByID = source.SetCurrencyBackpackByID
      target.setCurrencyFilter = source.SetCurrencyFilter
      target.setCurrencyUnused = source.SetCurrencyUnused
    end
  end
  do
    local source = host.C_Cursor
    if source then
      local target = {}
      api.cursor = target
      target.getCursorItem = source.GetCursorItem
    end
  end
  do
    local source = host.C_CursorUtil
    if source then
      local target = {}
      api.cursorUtil = target
    end
  end
  do
    local source = host.C_CurveUtil
    if source then
      local target = {}
      api.curveUtil = target
      target.createColorCurve = source.CreateColorCurve
      target.createCurve = source.CreateCurve
      target.evaluateColorFromBoolean = source.EvaluateColorFromBoolean
      target.evaluateColorValueFromBoolean = source.EvaluateColorValueFromBoolean
      target.evaluateGameCurve = source.EvaluateGameCurve
    end
  end
  do
    local source = host.C_CVar
    if source then
      local target = {}
      api.cvar = target
      target.areCVarsLoaded = source.AreCVarsLoaded
      target.getCVar = source.GetCVar
      target.getCVarBitfield = source.GetCVarBitfield
      target.getCVarBool = source.GetCVarBool
      target.getCVarDefault = source.GetCVarDefault
      target.getCVarInfo = source.GetCVarInfo
      target.registerCVar = source.RegisterCVar
      target.resetTestCVars = source.ResetTestCVars
      target.setCVar = source.SetCVar
      target.setCVarBitfield = source.SetCVarBitfield
    end
  end
  do
    local source = host.C_DamageMeter
    if source then
      local target = {}
      api.damageMeter = target
      target.getAvailableCombatSessions = source.GetAvailableCombatSessions
      target.getCombatSessionFromID = source.GetCombatSessionFromID
      target.getCombatSessionFromType = source.GetCombatSessionFromType
      target.getCombatSessionSourceFromID = source.GetCombatSessionSourceFromID
      target.getCombatSessionSourceFromType = source.GetCombatSessionSourceFromType
      target.getSessionDurationSeconds = source.GetSessionDurationSeconds
      target.isDamageMeterAvailable = source.IsDamageMeterAvailable
      target.resetAllCombatSessions = source.ResetAllCombatSessions
    end
  end
  do
    local source = host.C_DateAndTime
    if source then
      local target = {}
      api.dateAndTime = target
      target.adjustTimeByDays = source.AdjustTimeByDays
      target.adjustTimeByMinutes = source.AdjustTimeByMinutes
      target.adjustTimeByMonths = source.AdjustTimeByMonths
      target.compareCalendarTime = source.CompareCalendarTime
      target.getCalendarTimeFromEpoch = source.GetCalendarTimeFromEpoch
      target.getCurrentCalendarTime = source.GetCurrentCalendarTime
      target.getSecondsUntilDailyReset = source.GetSecondsUntilDailyReset
      target.getSecondsUntilWeeklyReset = source.GetSecondsUntilWeeklyReset
      target.getServerTimeLocal = source.GetServerTimeLocal
      target.getWeeklyResetStartTime = source.GetWeeklyResetStartTime
    end
  end
  do
    local source = host.C_DeathAlert
    if source then
      local target = {}
      api.deathAlert = target
    end
  end
  do
    local source = host.C_DeathInfo
    if source then
      local target = {}
      api.deathInfo = target
      target.getCorpseMapPosition = source.GetCorpseMapPosition
      target.getDeathReleasePosition = source.GetDeathReleasePosition
      target.getGraveyardsForMap = source.GetGraveyardsForMap
      target.getSelfResurrectOptions = source.GetSelfResurrectOptions
      target.useSelfResurrectOption = source.UseSelfResurrectOption
    end
  end
  do
    local source = host.C_DeathRecap
    if source then
      local target = {}
      api.deathRecap = target
      target.getRecapEvents = source.GetRecapEvents
      target.getRecapLink = source.GetRecapLink
      target.getRecapMaxHealth = source.GetRecapMaxHealth
      target.hasRecapEvents = source.HasRecapEvents
    end
  end
  do
    local target = {}
    api.debugToggle = target
    target.isCollisionEnabled = host.IsCollisionEnabled
    target.toggleAnimKitDisplay = host.ToggleAnimKitDisplay
    target.toggleCollision = host.ToggleCollision
    target.toggleCollisionDisplay = host.ToggleCollisionDisplay
    target.toggleDebugAIDisplay = host.ToggleDebugAIDisplay
    target.toggleGravity = host.ToggleGravity
    target.togglePlayerBounds = host.TogglePlayerBounds
    target.togglePortals = host.TogglePortals
    target.toggleTris = host.ToggleTris
  end
  do
    local source = host.C_DelvesUI
    if source then
      local target = {}
      api.delvesUI = target
      target.getActiveDelveTier = source.GetActiveDelveTier
      target.getCompanionInfoForActivePlayer = source.GetCompanionInfoForActivePlayer
      target.getCreatureDisplayInfoForCompanion = source.GetCreatureDisplayInfoForCompanion
      target.getCurioLink = source.GetCurioLink
      target.getCurioNodeForCompanion = source.GetCurioNodeForCompanion
      target.getCurioRarityByTraitCondAccountElementID =
        source.GetCurioRarityByTraitCondAccountElementID
      target.getCurrentDelvesSeasonNumber = source.GetCurrentDelvesSeasonNumber
      target.getDelveEntranceBackgroundWidgetSetID = source.GetDelveEntranceBackgroundWidgetSetID
      target.getDelveEntranceDescriptionString = source.GetDelveEntranceDescriptionString
      target.getDelveEntranceHeaderString = source.GetDelveEntranceHeaderString
      target.getDelveEntranceMapID = source.GetDelveEntranceMapID
      target.getDelveEntranceTiers = source.GetDelveEntranceTiers
      target.getDelveEntranceTitleString = source.GetDelveEntranceTitleString
      target.getDelvesAffixSpellsForSeason = source.GetDelvesAffixSpellsForSeason
      target.getDelvesFactionForSeason = source.GetDelvesFactionForSeason
      target.getDelvesMinRequiredLevel = source.GetDelvesMinRequiredLevel
      target.getFactionForCompanion = source.GetFactionForCompanion
      target.getFlavorNodeForCompanion = source.GetFlavorNodeForCompanion
      target.getFlavorNodeNameForCompanion = source.GetFlavorNodeNameForCompanion
      target.getLockedTextForCompanion = source.GetLockedTextForCompanion
      target.getModelSceneForCompanion = source.GetModelSceneForCompanion
      target.getPlayerCompanionPDEID = source.GetPlayerCompanionPDEID
      target.getRoleNodeForCompanion = source.GetRoleNodeForCompanion
      target.getRoleSubtreeForCompanion = source.GetRoleSubtreeForCompanion
      target.getTieredEntranceOptionalAffixTraitTreeID =
        source.GetTieredEntranceOptionalAffixTraitTreeID
      target.getTieredEntrancePDEID = source.GetTieredEntrancePDEID
      target.getTieredEntranceType = source.GetTieredEntranceType
      target.getTraitTreeForCompanion = source.GetTraitTreeForCompanion
      target.getUnseenCuriosBySlotType = source.GetUnseenCuriosBySlotType
      target.getWorldTierDifficultyForActivePlayer = source.GetWorldTierDifficultyForActivePlayer
      target.hasActiveDelve = source.HasActiveDelve
      target.hasActiveLFGLair = source.HasActiveLFGLair
      target.hasActiveLair = source.HasActiveLair
      target.isDelveEntranceTierEnabled = source.IsDelveEntranceTierEnabled
      target.isEligibleForActiveDelveRewards = source.IsEligibleForActiveDelveRewards
      target.isInLair = source.IsInLair
      target.isTraitTreeForCompanion = source.IsTraitTreeForCompanion
      target.requestPartyEligibilityForDelveTiers = source.RequestPartyEligibilityForDelveTiers
      target.saveSeenCuriosBySlotType = source.SaveSeenCuriosBySlotType
      target.selectDelveEntranceTier = source.SelectDelveEntranceTier
    end
  end
  do
    local source = host.C_Discord
    if source then
      local target = {}
      api.discord = target
      target.authorize = source.Authorize
      target.getDiscordChannelName = source.GetDiscordChannelName
      target.getDiscordUserID = source.GetDiscordUserID
      target.getDiscordUserName = source.GetDiscordUserName
      target.getDisplayNameType = source.GetDisplayNameType
      target.getGuildLinkStatus = source.GetGuildLinkStatus
      target.getNumDiscordChannels = source.GetNumDiscordChannels
      target.getNumDiscordServers = source.GetNumDiscordServers
      target.getServerLinkableChannels = source.GetServerLinkableChannels
      target.getServerName = source.GetServerName
      target.guildLink = source.GuildLink
      target.guildUnlink = source.GuildUnlink
      target.isEnabled = source.IsEnabled
      target.isGuildChannelLinked = source.IsGuildChannelLinked
      target.isGuildSettingSet = source.IsGuildSettingSet
      target.isUserOAuthed = source.IsUserOAuthed
      target.refreshAuth = source.RefreshAuth
      target.setGuildSetting = source.SetGuildSetting
      target.updateDiscordServers = source.UpdateDiscordServers
      target.updateGuildLobby = source.UpdateGuildLobby
    end
  end
  do
    local source = host.C_DuelInfo
    if source then
      local target = {}
      api.duelInfo = target
    end
  end
  do
    local source = host.C_DurationUtil
    if source then
      local target = {}
      api.durationUtil = target
      target.createDuration = source.CreateDuration
      target.createDurationTextBinding = source.CreateDurationTextBinding
      target.createManualClock = source.CreateManualClock
    end
  end
  do
    local source = host.C_DyeColor
    if source then
      local target = {}
      api.dyeColor = target
      target.getAllDyeColorCategories = source.GetAllDyeColorCategories
      target.getAllDyeColors = source.GetAllDyeColors
      target.getDyeColorCategoryInfo = source.GetDyeColorCategoryInfo
      target.getDyeColorInfo = source.GetDyeColorInfo
      target.getDyeColorsForItem = source.GetDyeColorsForItem
      target.getDyeColorsForItemLocation = source.GetDyeColorsForItemLocation
      target.getDyeColorsInCategory = source.GetDyeColorsInCategory
      target.isDyeColorOwned = source.IsDyeColorOwned
    end
  end
  do
    local source = host.C_EditMode
    if source then
      local target = {}
      api.editMode = target
      target.convertLayoutInfoToString = source.ConvertLayoutInfoToString
      target.convertStringToLayoutInfo = source.ConvertStringToLayoutInfo
      target.getAccountSettings = source.GetAccountSettings
      target.getLayouts = source.GetLayouts
      target.isValidLayoutName = source.IsValidLayoutName
      target.onEditModeExit = source.OnEditModeExit
      target.onLayoutAdded = source.OnLayoutAdded
      target.onLayoutDeleted = source.OnLayoutDeleted
      target.saveLayouts = source.SaveLayouts
      target.setAccountSetting = source.SetAccountSetting
      target.setActiveLayout = source.SetActiveLayout
    end
  end
  do
    local source = host.C_EncodingUtil
    if source then
      local target = {}
      api.encodingUtil = target
      target.compressString = source.CompressString
      target.decodeBase64 = source.DecodeBase64
      target.decodeHex = source.DecodeHex
      target.decompressString = source.DecompressString
      target.deserializeCBOR = source.DeserializeCBOR
      target.deserializeJSON = source.DeserializeJSON
      target.encodeBase64 = source.EncodeBase64
      target.encodeHex = source.EncodeHex
      target.serializeCBOR = source.SerializeCBOR
      target.serializeJSON = source.SerializeJSON
    end
  end
  do
    local source = host.C_EncounterEvents
    if source then
      local target = {}
      api.encounterEvents = target
      target.getEventColor = source.GetEventColor
      target.getEventInfo = source.GetEventInfo
      target.getEventList = source.GetEventList
      target.getEventSound = source.GetEventSound
      target.hasEventInfo = source.HasEventInfo
      target.playEventSound = source.PlayEventSound
      target.setEventColor = source.SetEventColor
      target.setEventSound = source.SetEventSound
    end
  end
  do
    local source = host.C_EncounterInfo
    if source then
      local target = {}
      api.encounterInfo = target
    end
  end
  do
    local source = host.C_EncounterJournal
    if source then
      local target = {}
      api.encounterJournal = target
      target.getBaseDifficultyID = source.GetBaseDifficultyID
      target.getDungeonEntrancesForMap = source.GetDungeonEntrancesForMap
      target.getEncounterJournalLink = source.GetEncounterJournalLink
      target.getEncountersOnMap = source.GetEncountersOnMap
      target.getInstanceForGameMap = source.GetInstanceForGameMap
      target.getLootInfo = source.GetLootInfo
      target.getLootInfoByIndex = source.GetLootInfoByIndex
      target.getSectionIconFlags = source.GetSectionIconFlags
      target.getSectionInfo = source.GetSectionInfo
      target.getSlotFilter = source.GetSlotFilter
      target.initalizeSelectedTier = source.InitalizeSelectedTier
      target.instanceHasDifficultyID = source.InstanceHasDifficultyID
      target.instanceHasLoot = source.InstanceHasLoot
      target.isEncounterComplete = source.IsEncounterComplete
      target.onClose = source.OnClose
      target.onOpen = source.OnOpen
      target.resetSlotFilter = source.ResetSlotFilter
      target.setPreviewMythicPlusLevel = source.SetPreviewMythicPlusLevel
      target.setPreviewPvpTier = source.SetPreviewPvpTier
      target.setSlotFilter = source.SetSlotFilter
      target.setTab = source.SetTab
      target.startArathiRPE = source.StartArathiRPE
    end
  end
  do
    local source = host.C_EncounterTimeline
    if source then
      local target = {}
      api.encounterTimeline = target
      target.addEditModeEvents = source.AddEditModeEvents
      target.addScriptEvent = source.AddScriptEvent
      target.cancelAllScriptEvents = source.CancelAllScriptEvents
      target.cancelEditModeEvents = source.CancelEditModeEvents
      target.cancelScriptEvent = source.CancelScriptEvent
      target.finishScriptEvent = source.FinishScriptEvent
      target.getCurrentTime = source.GetCurrentTime
      target.getEventColor = source.GetEventColor
      target.getEventCountBySource = source.GetEventCountBySource
      target.getEventHighlightTime = source.GetEventHighlightTime
      target.getEventInfo = source.GetEventInfo
      target.getEventList = source.GetEventList
      target.getEventState = source.GetEventState
      target.getEventTimeElapsed = source.GetEventTimeElapsed
      target.getEventTimeRemaining = source.GetEventTimeRemaining
      target.getEventTimer = source.GetEventTimer
      target.getEventTrack = source.GetEventTrack
      target.getSortedEventList = source.GetSortedEventList
      target.getTrackInfo = source.GetTrackInfo
      target.getTrackList = source.GetTrackList
      target.getTrackMaxEventDuration = source.GetTrackMaxEventDuration
      target.getTrackType = source.GetTrackType
      target.getViewType = source.GetViewType
      target.hasActiveEvents = source.HasActiveEvents
      target.hasAnyEvents = source.HasAnyEvents
      target.hasPausedEvents = source.HasPausedEvents
      target.hasVisibleEvents = source.HasVisibleEvents
      target.isEventBlocked = source.IsEventBlocked
      target.isFeatureAvailable = source.IsFeatureAvailable
      target.isFeatureEnabled = source.IsFeatureEnabled
      target.pauseScriptEvent = source.PauseScriptEvent
      target.resumeScriptEvent = source.ResumeScriptEvent
      target.setEventIconTextures = source.SetEventIconTextures
      target.setViewType = source.SetViewType
    end
  end
  do
    local source = host.C_EncounterWarnings
    if source then
      local target = {}
      api.encounterWarnings = target
      target.getColorForSeverity = source.GetColorForSeverity
      target.getEditModeWarningInfo = source.GetEditModeWarningInfo
      target.getPlayCustomSoundsWhenHidden = source.GetPlayCustomSoundsWhenHidden
      target.getSoundKitForSeverity = source.GetSoundKitForSeverity
      target.getWarningsShown = source.GetWarningsShown
      target.isFeatureAvailable = source.IsFeatureAvailable
      target.isFeatureEnabled = source.IsFeatureEnabled
      target.playSound = source.PlaySound
      target.setPlayCustomSoundsWhenHidden = source.SetPlayCustomSoundsWhenHidden
      target.setWarningsShown = source.SetWarningsShown
    end
  end
  do
    local source = host.C_EndOfMatchUI
    if source then
      local target = {}
      api.endOfMatchUI = target
      target.getEndOfMatchDetails = source.GetEndOfMatchDetails
    end
  end
  do
    local source = host.C_EquipmentSet
    if source then
      local target = {}
      api.equipmentSet = target
      target.assignSpecToEquipmentSet = source.AssignSpecToEquipmentSet
      target.canUseEquipmentSets = source.CanUseEquipmentSets
      target.clearIgnoredSlotsForSave = source.ClearIgnoredSlotsForSave
      target.createEquipmentSet = source.CreateEquipmentSet
      target.deleteEquipmentSet = source.DeleteEquipmentSet
      target.equipmentSetContainsLockedItems = source.EquipmentSetContainsLockedItems
      target.getEquipmentSetAssignedSpec = source.GetEquipmentSetAssignedSpec
      target.getEquipmentSetForSpec = source.GetEquipmentSetForSpec
      target.getEquipmentSetID = source.GetEquipmentSetID
      target.getEquipmentSetIDs = source.GetEquipmentSetIDs
      target.getEquipmentSetInfo = source.GetEquipmentSetInfo
      target.getIgnoredSlots = source.GetIgnoredSlots
      target.getItemIDs = source.GetItemIDs
      target.getItemLocations = source.GetItemLocations
      target.getNumEquipmentSets = source.GetNumEquipmentSets
      target.ignoreSlotForSave = source.IgnoreSlotForSave
      target.isSlotIgnoredForSave = source.IsSlotIgnoredForSave
      target.modifyEquipmentSet = source.ModifyEquipmentSet
      target.pickupEquipmentSet = source.PickupEquipmentSet
      target.saveEquipmentSet = source.SaveEquipmentSet
      target.unassignEquipmentSetSpec = source.UnassignEquipmentSetSpec
      target.unignoreSlotForSave = source.UnignoreSlotForSave
      target.useEquipmentSet = source.UseEquipmentSet
    end
  end
  do
    local source = host.C_EventScheduler
    if source then
      local target = {}
      api.eventScheduler = target
      target.canShowEvents = source.CanShowEvents
      target.clearReminder = source.ClearReminder
      target.getActiveContinentName = source.GetActiveContinentName
      target.getEventUiMapID = source.GetEventUiMapID
      target.getEventZoneName = source.GetEventZoneName
      target.getOngoingEvents = source.GetOngoingEvents
      target.getScheduledEvents = source.GetScheduledEvents
      target.hasData = source.HasData
      target.hasSavedReminders = source.HasSavedReminders
      target.requestEvents = source.RequestEvents
      target.setReminder = source.SetReminder
    end
  end
  do
    local source = host.C_EventToastManager
    if source then
      local target = {}
      api.eventToastManager = target
      target.getLevelUpDisplayToastsFromLevel = source.GetLevelUpDisplayToastsFromLevel
      target.getNextToastToDisplay = source.GetNextToastToDisplay
      target.removeCurrentToast = source.RemoveCurrentToast
    end
  end
  do
    local source = host.C_EventUtils
    if source then
      local target = {}
      api.eventUtils = target
      target.isCallbackEvent = source.IsCallbackEvent
      target.isEventValid = source.IsEventValid
    end
  end
  do
    local target = {}
    api.expansion = target
    target.canUpgradeToCurrentExpansion = host.CanUpgradeToCurrentExpansion
    target.doesCurrentLocaleSellExpansionLevels = host.DoesCurrentLocaleSellExpansionLevels
    target.getAccountExpansionLevel = host.GetAccountExpansionLevel
    target.getClientDisplayExpansionLevel = host.GetClientDisplayExpansionLevel
    target.getCurrentRegionName = host.GetCurrentRegionName
    target.getExpansionDisplayInfo = host.GetExpansionDisplayInfo
    target.getExpansionForLevel = host.GetExpansionForLevel
    target.getExpansionLevel = host.GetExpansionLevel
    target.getExpansionTrialInfo = host.GetExpansionTrialInfo
    target.getMaxLevelForExpansionLevel = host.GetMaxLevelForExpansionLevel
    target.getMaxLevelForLatestExpansion = host.GetMaxLevelForLatestExpansion
    target.getMaxLevelForPlayerExpansion = host.GetMaxLevelForPlayerExpansion
    target.getMaximumExpansionLevel = host.GetMaximumExpansionLevel
    target.getMinimumExpansionLevel = host.GetMinimumExpansionLevel
    target.getNumExpansions = host.GetNumExpansions
    target.getServerExpansionLevel = host.GetServerExpansionLevel
    target.getUpgradeExpansionLevel = host.GetUpgradeExpansionLevel
    target.isDemonHunterAvailable = host.IsDemonHunterAvailable
    target.isExpansionTrial = host.IsExpansionTrial
    target.isTrialAccount = host.IsTrialAccount
    target.isVeteranTrialAccount = host.IsVeteranTrialAccount
    target.sendSubscriptionInterstitialResponse = host.SendSubscriptionInterstitialResponse
    target.shouldShowExpansionUpgradeBanner = host.ShouldShowExpansionUpgradeBanner
  end
  do
    local target = {}
    api.expansionInfo = target
    target.classicExpansionAtLeast = host.ClassicExpansionAtLeast
    target.classicExpansionAtMost = host.ClassicExpansionAtMost
    target.getClassicExpansionLevel = host.GetClassicExpansionLevel
  end
  do
    local source = host.C_ExpansionTrial
    if source then
      local target = {}
      api.expansionTrial = target
      target.onTrialLevelUpDialogClicked = source.OnTrialLevelUpDialogClicked
      target.onTrialLevelUpDialogShown = source.OnTrialLevelUpDialogShown
    end
  end
  do
    local source = host.C_ExternalEventURL
    if source then
      local target = {}
      api.externalEventURL = target
      target.hasURL = source.HasURL
      target.isNew = source.IsNew
      target.launchURL = source.LaunchURL
    end
  end
  do
    local source = host.C_FogOfWar
    if source then
      local target = {}
      api.fogOfWar = target
      target.getFogOfWarForMap = source.GetFogOfWarForMap
      target.getFogOfWarInfo = source.GetFogOfWarInfo
    end
  end
  do
    local target = {}
    api.font = target
    target.createFontFamily = host.CreateFontFamily
    target.getFontInfo = host.GetFontInfo
    target.getFonts = host.GetFonts
  end
  do
    local source = host.C_FrameManager
    if source then
      local target = {}
      api.frameManager = target
      target.getFrameVisibilityState = source.GetFrameVisibilityState
    end
  end
  do
    local target = {}
    api.frameScript = target
    target.addSourceLocationExclude = host.AddSourceLocationExclude
    target.createFromMixins = host.CreateFromMixins
    target.createSecureDelegate = host.CreateSecureDelegate
    target.createWindow = host.CreateWindow
    target.getCallstackHeight = host.GetCallstackHeight
    target.getCurrentEventID = host.GetCurrentEventID
    target.getErrorCallstackHeight = host.GetErrorCallstackHeight
    target.getEventTime = host.GetEventTime
    target.getForbiddenObjectTable = host.GetForbiddenObjectTable
    target.getSourceLocation = host.GetSourceLocation
    target.mixin = host.Mixin
    target.registerEventCallback = host.RegisterEventCallback
    target.registerUnitEventCallback = host.RegisterUnitEventCallback
    target.runScript = host.RunScript
    target.setErrorCallstackHeight = host.SetErrorCallstackHeight
    target.unregisterEventCallback = host.UnregisterEventCallback
    target.unregisterUnitEventCallback = host.UnregisterUnitEventCallback
    target.canaccessallvalues = host.canaccessallvalues
    target.canaccesssecrets = host.canaccesssecrets
    target.canaccesstable = host.canaccesstable
    target.canaccessvalue = host.canaccessvalue
    target.debugprofilestart = host.debugprofilestart
    target.debugprofilestop = host.debugprofilestop
    target.dropsecretaccess = host.dropsecretaccess
    target.dumpobject = host.dumpobject
    target.hasanysecretvalues = host.hasanysecretvalues
    target.issecrettable = host.issecrettable
    target.issecretvalue = host.issecretvalue
    target.mapvalues = host.mapvalues
    target.scrub = host.scrub
    target.scrubsecretvalues = host.scrubsecretvalues
    target.secretunwrap = host.secretunwrap
    target.secretwrap = host.secretwrap
    target.securecallmethod = host.securecallmethod
    target.securecopy = host.securecopy
    target.settablesecurity = host.settablesecurity
  end
  do
    local source = host.C_FriendList
    if source then
      local target = {}
      api.friendList = target
      target.addFriend = source.AddFriend
      target.addIgnore = source.AddIgnore
      target.addOrDelIgnore = source.AddOrDelIgnore
      target.addOrRemoveFriend = source.AddOrRemoveFriend
      target.delIgnore = source.DelIgnore
      target.delIgnoreByIndex = source.DelIgnoreByIndex
      target.getFriendInfo = source.GetFriendInfo
      target.getFriendInfoByIndex = source.GetFriendInfoByIndex
      target.getIgnoreName = source.GetIgnoreName
      target.getNumFriends = source.GetNumFriends
      target.getNumIgnores = source.GetNumIgnores
      target.getNumOnlineFriends = source.GetNumOnlineFriends
      target.getNumWhoResults = source.GetNumWhoResults
      target.getSelectedFriend = source.GetSelectedFriend
      target.getSelectedIgnore = source.GetSelectedIgnore
      target.getWhoInfo = source.GetWhoInfo
      target.isFriend = source.IsFriend
      target.isIgnored = source.IsIgnored
      target.isIgnoredByGuid = source.IsIgnoredByGuid
      target.isLegacyFriendSystemEnabled = source.IsLegacyFriendSystemEnabled
      target.isOnIgnoredList = source.IsOnIgnoredList
      target.removeFriend = source.RemoveFriend
      target.removeFriendByIndex = source.RemoveFriendByIndex
      target.sendWho = source.SendWho
      target.setFriendNotes = source.SetFriendNotes
      target.setFriendNotesByIndex = source.SetFriendNotesByIndex
      target.setSelectedFriend = source.SetSelectedFriend
      target.setSelectedIgnore = source.SetSelectedIgnore
      target.setWhoToUi = source.SetWhoToUi
      target.showFriends = source.ShowFriends
      target.sortWho = source.SortWho
    end
  end
  do
    local target = {}
    api.gameCursor = target
    target.clearCursor = host.ClearCursor
    target.clearCursorHoveredItem = host.ClearCursorHoveredItem
    target.cursorHasItem = host.CursorHasItem
    target.cursorHasMacro = host.CursorHasMacro
    target.cursorHasMoney = host.CursorHasMoney
    target.cursorHasSpell = host.CursorHasSpell
    target.deleteCursorItem = host.DeleteCursorItem
    target.dropCursorMoney = host.DropCursorMoney
    target.equipCursorItem = host.EquipCursorItem
    target.getCursorInfo = host.GetCursorInfo
    target.getCursorMoney = host.GetCursorMoney
    target.pickupPlayerMoney = host.PickupPlayerMoney
    target.resetCursor = host.ResetCursor
    target.sellCursorItem = host.SellCursorItem
    target.setCursor = host.SetCursor
    target.setCursorByMode = host.SetCursorByMode
    target.setCursorHoveredItem = host.SetCursorHoveredItem
    target.setCursorHoveredItemTradeItem = host.SetCursorHoveredItemTradeItem
    target.setCursorVirtualItem = host.SetCursorVirtualItem
  end
  do
    local target = {}
    api.gameError = target
    target.getGameMessageInfo = host.GetGameMessageInfo
    target.notWhileDeadError = host.NotWhileDeadError
  end
  do
    local source = host.C_GamePad
    if source then
      local target = {}
      api.gamePad = target
      target.addSDLMapping = source.AddSDLMapping
      target.applyConfigs = source.ApplyConfigs
      target.axisIndexToConfigName = source.AxisIndexToConfigName
      target.buttonBindingToIndex = source.ButtonBindingToIndex
      target.buttonIndexToBinding = source.ButtonIndexToBinding
      target.buttonIndexToConfigName = source.ButtonIndexToConfigName
      target.clearLedColor = source.ClearLedColor
      target.deleteConfig = source.DeleteConfig
      target.getActiveDeviceID = source.GetActiveDeviceID
      target.getAllConfigIDs = source.GetAllConfigIDs
      target.getAllDeviceIDs = source.GetAllDeviceIDs
      target.getCombinedDeviceID = source.GetCombinedDeviceID
      target.getConfig = source.GetConfig
      target.getDeviceMappedState = source.GetDeviceMappedState
      target.getDeviceRawState = source.GetDeviceRawState
      target.getLedColor = source.GetLedColor
      target.getPowerLevel = source.GetPowerLevel
      target.isEnabled = source.IsEnabled
      target.setConfig = source.SetConfig
      target.setLedColor = source.SetLedColor
      target.setVibration = source.SetVibration
      target.stickIndexToConfigName = source.StickIndexToConfigName
      target.stopVibration = source.StopVibration
    end
  end
  do
    local source = host.C_GameRules
    if source then
      local target = {}
      api.gameRules = target
      target.autoConnectToGameModeRealm = source.AutoConnectToGameModeRealm
      target.doesGameModeHavePromo = source.DoesGameModeHavePromo
      target.getActiveGameMode = source.GetActiveGameMode
      target.getCurrentEventRealmQueues = source.GetCurrentEventRealmQueues
      target.getCurrentGameModeDisplayInfo = source.GetCurrentGameModeDisplayInfo
      target.getCurrentGameModeRecordID = source.GetCurrentGameModeRecordID
      target.getDisplayedGameModeRecordIDAtIndex = source.GetDisplayedGameModeRecordIDAtIndex
      target.getGameModeDisplayInfoByRecordID = source.GetGameModeDisplayInfoByRecordID
      target.getGameModeGlueScreenName = source.GetGameModeGlueScreenName
      target.getGameModePromoGlobalString = source.GetGameModePromoGlobalString
      target.getGameRuleAsFloat = source.GetGameRuleAsFloat
      target.getGameRuleAsFrameStrata = source.GetGameRuleAsFrameStrata
      target.getNumDisplayedGameModes = source.GetNumDisplayedGameModes
      target.isCharacterlessLoginActive = source.IsCharacterlessLoginActive
      target.isClassAllowedForGameMode = source.IsClassAllowedForGameMode
      target.isGameModeEnabled = source.IsGameModeEnabled
      target.isGameRuleActive = source.IsGameRuleActive
      target.isMultiActionBarVisibilityForced = source.IsMultiActionBarVisibilityForced
      target.isPersonalResourceDisplayEnabled = source.IsPersonalResourceDisplayEnabled
      target.isPlunderstorm = source.IsPlunderstorm
      target.isStandard = source.IsStandard
      target.isWoWHack = source.IsWoWHack
    end
  end
  do
    local target = {}
    api.gameUI = target
    target.setInWorldUIVisibility = host.SetInWorldUIVisibility
    target.setUIVisibility = host.SetUIVisibility
  end
  do
    local source = host.C_Garrison
    if source then
      local target = {}
      api.garrison = target
      target.addFollowerToMission = source.AddFollowerToMission
      target.getAutoCombatDamageClassValues = source.GetAutoCombatDamageClassValues
      target.getAutoMissionBoardState = source.GetAutoMissionBoardState
      target.getAutoMissionEnvironmentEffect = source.GetAutoMissionEnvironmentEffect
      target.getAutoMissionTargetingInfo = source.GetAutoMissionTargetingInfo
      target.getAutoMissionTargetingInfoForSpell = source.GetAutoMissionTargetingInfoForSpell
      target.getAutoTroops = source.GetAutoTroops
      target.getCombatLogSpellInfo = source.GetCombatLogSpellInfo
      target.getCurrentCypherEquipmentLevel = source.GetCurrentCypherEquipmentLevel
      target.getCurrentGarrTalentTreeFriendshipFactionID =
        source.GetCurrentGarrTalentTreeFriendshipFactionID
      target.getCurrentGarrTalentTreeID = source.GetCurrentGarrTalentTreeID
      target.getCyphersToNextEquipmentLevel = source.GetCyphersToNextEquipmentLevel
      target.getFollowerAutoCombatSpells = source.GetFollowerAutoCombatSpells
      target.getFollowerAutoCombatStats = source.GetFollowerAutoCombatStats
      target.getFollowerMissionCompleteInfo = source.GetFollowerMissionCompleteInfo
      target.getGarrisonPlotsInstancesForMap = source.GetGarrisonPlotsInstancesForMap
      target.getGarrisonTalentTreeCurrencyTypes = source.GetGarrisonTalentTreeCurrencyTypes
      target.getGarrisonTalentTreeType = source.GetGarrisonTalentTreeType
      target.getMaxCypherEquipmentLevel = source.GetMaxCypherEquipmentLevel
      target.getMissionCompleteEncounters = source.GetMissionCompleteEncounters
      target.getMissionDeploymentInfo = source.GetMissionDeploymentInfo
      target.getMissionEncounterIconInfo = source.GetMissionEncounterIconInfo
      target.getTalentInfo = source.GetTalentInfo
      target.getTalentPointsSpentInTalentTree = source.GetTalentPointsSpentInTalentTree
      target.getTalentTreeIDsByClassID = source.GetTalentTreeIDsByClassID
      target.getTalentTreeInfo = source.GetTalentTreeInfo
      target.getTalentTreeResetInfo = source.GetTalentTreeResetInfo
      target.getTalentTreeTalentPointResearchInfo = source.GetTalentTreeTalentPointResearchInfo
      target.getTalentUnlockWorldQuest = source.GetTalentUnlockWorldQuest
      target.hasAdventures = source.HasAdventures
      target.isAtGarrisonMissionNPC = source.IsAtGarrisonMissionNPC
      target.isEnvironmentCountered = source.IsEnvironmentCountered
      target.isFollowerOnCompletedMission = source.IsFollowerOnCompletedMission
      target.isLandingPageMinimapButtonVisible = source.IsLandingPageMinimapButtonVisible
      target.isTalentConditionMet = source.IsTalentConditionMet
      target.regenerateCombatLog = source.RegenerateCombatLog
      target.removeFollowerFromMission = source.RemoveFollowerFromMission
      target.rushHealAllFollowers = source.RushHealAllFollowers
      target.rushHealFollower = source.RushHealFollower
      target.setAutoCombatSpellFastForward = source.SetAutoCombatSpellFastForward
    end
  end
  do
    local source = host.C_GenericWidgetDisplay
    if source then
      local target = {}
      api.genericWidgetDisplay = target
      target.acknowledge = source.Acknowledge
      target.close = source.Close
    end
  end
  do
    local source = host.C_Glue
    if source then
      local target = {}
      api.glue = target
      target.isFirstLoadThisSession = source.IsFirstLoadThisSession
      target.isOnGlueScreen = source.IsOnGlueScreen
    end
  end
  do
    local source = host.C_GlyphInfo
    if source then
      local target = {}
      api.glyphInfo = target
    end
  end
  do
    local source = host.C_GMTicketInfo
    if source then
      local target = {}
      api.gmTicketInfo = target
    end
  end
  do
    local source = host.C_GossipInfo
    if source then
      local target = {}
      api.gossipInfo = target
      target.closeGossip = source.CloseGossip
      target.forceGossip = source.ForceGossip
      target.getActiveQuests = source.GetActiveQuests
      target.getAvailableQuests = source.GetAvailableQuests
      target.getCompletedOptionDescriptionString = source.GetCompletedOptionDescriptionString
      target.getCustomGossipDescriptionString = source.GetCustomGossipDescriptionString
      target.getFriendshipReputation = source.GetFriendshipReputation
      target.getFriendshipReputationRanks = source.GetFriendshipReputationRanks
      target.getNumActiveQuests = source.GetNumActiveQuests
      target.getNumAvailableQuests = source.GetNumAvailableQuests
      target.getOptionUIWidgetSetsAndTypesByOptionID =
        source.GetOptionUIWidgetSetsAndTypesByOptionID
      target.getOptions = source.GetOptions
      target.getPoiForUiMapID = source.GetPoiForUiMapID
      target.getPoiInfo = source.GetPoiInfo
      target.getText = source.GetText
      target.refreshOptions = source.RefreshOptions
      target.selectActiveQuest = source.SelectActiveQuest
      target.selectAvailableQuest = source.SelectAvailableQuest
      target.selectOption = source.SelectOption
      target.selectOptionByIndex = source.SelectOptionByIndex
    end
  end
  do
    local source = host.C_GuildBank
    if source then
      local target = {}
      api.guildBank = target
      target.isGuildBankEnabled = source.IsGuildBankEnabled
    end
  end
  do
    local source = host.C_GuildInfo
    if source then
      local target = {}
      api.guildInfo = target
      target.areGuildEventsEnabled = source.AreGuildEventsEnabled
      target.canEditOfficerNote = source.CanEditOfficerNote
      target.canSpeakInGuildChat = source.CanSpeakInGuildChat
      target.canViewOfficerNote = source.CanViewOfficerNote
      target.demote = source.Demote
      target.disband = source.Disband
      target.getGuildNewsInfo = source.GetGuildNewsInfo
      target.getGuildRankOrder = source.GetGuildRankOrder
      target.getGuildTabardInfo = source.GetGuildTabardInfo
      target.getInfoText = source.GetInfoText
      target.getMOTD = source.GetMOTD
      target.guildControlGetRankFlags = source.GuildControlGetRankFlags
      target.guildRoster = source.GuildRoster
      target.invite = source.Invite
      target.isDiscordStreamSeparate = source.IsDiscordStreamSeparate
      target.isEncounterGuildNewsEnabled = source.IsEncounterGuildNewsEnabled
      target.isGuildOfficer = source.IsGuildOfficer
      target.isGuildRankAssignmentAllowed = source.IsGuildRankAssignmentAllowed
      target.isGuildReputationEnabled = source.IsGuildReputationEnabled
      target.leave = source.Leave
      target.memberExistsByName = source.MemberExistsByName
      target.promote = source.Promote
      target.queryGuildMemberRecipes = source.QueryGuildMemberRecipes
      target.queryGuildMembersForRecipe = source.QueryGuildMembersForRecipe
      target.removeFromGuild = source.RemoveFromGuild
      target.requestGuildRename = source.RequestGuildRename
      target.requestGuildRenameRefund = source.RequestGuildRenameRefund
      target.requestRenameNameCheck = source.RequestRenameNameCheck
      target.requestRenameStatus = source.RequestRenameStatus
      target.setGuildRankOrder = source.SetGuildRankOrder
      target.setInfoText = source.SetInfoText
      target.setLeader = source.SetLeader
      target.setMOTD = source.SetMOTD
      target.setNote = source.SetNote
      target.uninvite = source.Uninvite
    end
  end
  do
    local source = host.C_HeirloomInfo
    if source then
      local target = {}
      api.heirloomInfo = target
      target.areAllCollectionFiltersChecked = source.AreAllCollectionFiltersChecked
      target.areAllSourceFiltersChecked = source.AreAllSourceFiltersChecked
      target.isHeirloomSourceValid = source.IsHeirloomSourceValid
      target.isUsingDefaultFilters = source.IsUsingDefaultFilters
      target.setAllCollectionFilters = source.SetAllCollectionFilters
      target.setAllSourceFilters = source.SetAllSourceFilters
      target.setDefaultFilters = source.SetDefaultFilters
    end
  end
  do
    local source = host.C_HouseEditor
    if source then
      local target = {}
      api.houseEditor = target
      target.activateHouseEditorMode = source.ActivateHouseEditorMode
      target.enterHouseEditor = source.EnterHouseEditor
      target.getActiveHouseEditorMode = source.GetActiveHouseEditorMode
      target.getHouseEditorAvailability = source.GetHouseEditorAvailability
      target.getHouseEditorModeAvailability = source.GetHouseEditorModeAvailability
      target.getHouseEditorPlayerType = source.GetHouseEditorPlayerType
      target.isHouseEditorActive = source.IsHouseEditorActive
      target.isHouseEditorModeActive = source.IsHouseEditorModeActive
      target.isHouseEditorStatusAvailable = source.IsHouseEditorStatusAvailable
      target.leaveHouseEditor = source.LeaveHouseEditor
    end
  end
  do
    local source = host.C_HouseExterior
    if source then
      local target = {}
      api.houseExterior = target
      target.cancelActiveExteriorEditing = source.CancelActiveExteriorEditing
      target.getCoreFixtureOptionsInfo = source.GetCoreFixtureOptionsInfo
      target.getCurrentHouseExteriorSize = source.GetCurrentHouseExteriorSize
      target.getCurrentHouseExteriorType = source.GetCurrentHouseExteriorType
      target.getHouseExteriorSizeOptions = source.GetHouseExteriorSizeOptions
      target.getHouseExteriorTypeOptions = source.GetHouseExteriorTypeOptions
      target.getSelectedFixturePointInfo = source.GetSelectedFixturePointInfo
      target.hasHoveredFixture = source.HasHoveredFixture
      target.hasSelectedFixturePoint = source.HasSelectedFixturePoint
      target.isAnyDecorAttachedToCoreFixture = source.IsAnyDecorAttachedToCoreFixture
      target.isAnyDecorAttachedToDoor = source.IsAnyDecorAttachedToDoor
      target.isAnyDecorAttachedToHouseExterior = source.IsAnyDecorAttachedToHouseExterior
      target.isAnyDecorAttachedToSelectedFixturePoint =
        source.IsAnyDecorAttachedToSelectedFixturePoint
      target.isExteriorDecorHidden = source.IsExteriorDecorHidden
      target.removeFixtureFromSelectedPoint = source.RemoveFixtureFromSelectedPoint
      target.selectCoreFixtureOption = source.SelectCoreFixtureOption
      target.selectFixtureOption = source.SelectFixtureOption
      target.setExteriorDecorHidden = source.SetExteriorDecorHidden
      target.setHouseExteriorSize = source.SetHouseExteriorSize
      target.setHouseExteriorType = source.SetHouseExteriorType
    end
  end
  do
    local source = host.C_Housing
    if source then
      local target = {}
      api.housing = target
      target.acceptNeighborhoodOwnership = source.AcceptNeighborhoodOwnership
      target.canEditCharter = source.CanEditCharter
      target.canTakeReportScreenshot = source.CanTakeReportScreenshot
      target.createGuildNeighborhood = source.CreateGuildNeighborhood
      target.createNeighborhoodCharter = source.CreateNeighborhoodCharter
      target.declineNeighborhoodOwnership = source.DeclineNeighborhoodOwnership
      target.doesFactionMatchNeighborhood = source.DoesFactionMatchNeighborhood
      target.editNeighborhoodCharter = source.EditNeighborhoodCharter
      target.getCurrentHouseInfo = source.GetCurrentHouseInfo
      target.getCurrentHouseLevelFavor = source.GetCurrentHouseLevelFavor
      target.getCurrentHouseRefundAmount = source.GetCurrentHouseRefundAmount
      target.getCurrentNeighborhoodGUID = source.GetCurrentNeighborhoodGUID
      target.getHouseLevelFavorForLevel = source.GetHouseLevelFavorForLevel
      target.getHouseLevelRewardsForLevel = source.GetHouseLevelRewardsForLevel
      target.getHousingAccessFlags = source.GetHousingAccessFlags
      target.getMaxHouseLevel = source.GetMaxHouseLevel
      target.getNeighborhoodTextureSuffix = source.GetNeighborhoodTextureSuffix
      target.getOthersOwnedHouses = source.GetOthersOwnedHouses
      target.getPlayerOwnedHouses = source.GetPlayerOwnedHouses
      target.getTrackedHouseGuid = source.GetTrackedHouseGuid
      target.getUIMapIDForNeighborhood = source.GetUIMapIDForNeighborhood
      target.getVisitCooldownInfo = source.GetVisitCooldownInfo
      target.hasHousingExpansionAccess = source.HasHousingExpansionAccess
      target.houseFinderDeclineNeighborhoodInvitation =
        source.HouseFinderDeclineNeighborhoodInvitation
      target.houseFinderIgnoreNeighborhood = source.HouseFinderIgnoreNeighborhood
      target.houseFinderRequestNeighborhoods = source.HouseFinderRequestNeighborhoods
      target.houseFinderRequestReservationAndPort = source.HouseFinderRequestReservationAndPort
      target.isHousingMarketCartFullRemoveEnabled = source.IsHousingMarketCartFullRemoveEnabled
      target.isHousingMarketEnabled = source.IsHousingMarketEnabled
      target.isHousingMarketShopEnabled = source.IsHousingMarketShopEnabled
      target.isHousingServiceEnabled = source.IsHousingServiceEnabled
      target.isInsideHouse = source.IsInsideHouse
      target.isInsideHouseOrPlot = source.IsInsideHouseOrPlot
      target.isInsideOwnedHouse = source.IsInsideOwnedHouse
      target.isInsideOwnedHouseOrPlot = source.IsInsideOwnedHouseOrPlot
      target.isInsideOwnedPlot = source.IsInsideOwnedPlot
      target.isInsidePlot = source.IsInsidePlot
      target.isOnNeighborhoodMap = source.IsOnNeighborhoodMap
      target.leaveHouse = source.LeaveHouse
      target.onCharterConfirmationAccepted = source.OnCharterConfirmationAccepted
      target.onCharterConfirmationClosed = source.OnCharterConfirmationClosed
      target.onCreateCharterNeighborhoodClosed = source.OnCreateCharterNeighborhoodClosed
      target.onCreateGuildNeighborhoodClosed = source.OnCreateGuildNeighborhoodClosed
      target.onHouseFinderClickPlot = source.OnHouseFinderClickPlot
      target.onRequestSignatureClicked = source.OnRequestSignatureClicked
      target.onSignCharterClicked = source.OnSignCharterClicked
      target.relinquishHouse = source.RelinquishHouse
      target.requestCurrentHouseInfo = source.RequestCurrentHouseInfo
      target.requestHouseFinderNeighborhoodData = source.RequestHouseFinderNeighborhoodData
      target.requestPlayerCharacterList = source.RequestPlayerCharacterList
      target.resetHouse = source.ResetHouse
      target.returnAfterVisitingHouse = source.ReturnAfterVisitingHouse
      target.saveHouseSettings = source.SaveHouseSettings
      target.searchBNetFriendNeighborhoods = source.SearchBNetFriendNeighborhoods
      target.searchBNetFriendNeighborhoodsByID = source.SearchBNetFriendNeighborhoodsByID
      target.setTrackedHouseGuid = source.SetTrackedHouseGuid
      target.startTutorial = source.StartTutorial
      target.teleportHome = source.TeleportHome
      target.tryRenameNeighborhood = source.TryRenameNeighborhood
      target.validateCreateGuildNeighborhoodSize = source.ValidateCreateGuildNeighborhoodSize
      target.validateNeighborhoodName = source.ValidateNeighborhoodName
      target.visitHouse = source.VisitHouse
    end
  end
  do
    local source = host.C_HousingBasicMode
    if source then
      local target = {}
      api.housingBasicMode = target
      target.cancelActiveEditing = source.CancelActiveEditing
      target.commitDecorMovement = source.CommitDecorMovement
      target.commitHouseExteriorPosition = source.CommitHouseExteriorPosition
      target.finishPlacingNewDecor = source.FinishPlacingNewDecor
      target.getHoveredDecorInfo = source.GetHoveredDecorInfo
      target.getSelectedDecorInfo = source.GetSelectedDecorInfo
      target.isDecorSelected = source.IsDecorSelected
      target.isFreePlaceEnabled = source.IsFreePlaceEnabled
      target.isGridSnapEnabled = source.IsGridSnapEnabled
      target.isGridVisible = source.IsGridVisible
      target.isHouseExteriorHovered = source.IsHouseExteriorHovered
      target.isHouseExteriorSelected = source.IsHouseExteriorSelected
      target.isHoveringDecor = source.IsHoveringDecor
      target.isPlacingNewDecor = source.IsPlacingNewDecor
      target.removeSelectedDecor = source.RemoveSelectedDecor
      target.rotateDecor = source.RotateDecor
      target.rotateHouseExterior = source.RotateHouseExterior
      target.setFreePlaceEnabled = source.SetFreePlaceEnabled
      target.setGridSnapEnabled = source.SetGridSnapEnabled
      target.setGridVisible = source.SetGridVisible
      target.startPlacingNewDecor = source.StartPlacingNewDecor
      target.startPlacingPreviewDecor = source.StartPlacingPreviewDecor
    end
  end
  do
    local source = host.C_HousingBlueprint
    if source then
      local target = {}
      api.housingBlueprint = target
      target.canExportRoom = source.CanExportRoom
      target.canExportTypeFromCurrentLocation = source.CanExportTypeFromCurrentLocation
      target.canImportTypeFromCurrentLocation = source.CanImportTypeFromCurrentLocation
      target.deleteBlueprint = source.DeleteBlueprint
      target.exportBlueprint = source.ExportBlueprint
      target.exportRoomBlueprint = source.ExportRoomBlueprint
      target.getBlueprintHyperlink = source.GetBlueprintHyperlink
      target.getBlueprintTypeForCode = source.GetBlueprintTypeForCode
      target.getExportAvailability = source.GetExportAvailability
      target.getFeatureAvailability = source.GetFeatureAvailability
      target.getImportAvailability = source.GetImportAvailability
      target.importBlueprint = source.ImportBlueprint
      target.isShareCodeValid = source.IsShareCodeValid
      target.renameBlueprint = source.RenameBlueprint
      target.requestBlueprintCollection = source.RequestBlueprintCollection
      target.requestBlueprintContents = source.RequestBlueprintContents
      target.requestBlueprintContentsForContext = source.RequestBlueprintContentsForContext
      target.startImportRoomBlueprint = source.StartImportRoomBlueprint
      target.updateBlueprintStringFromInput = source.UpdateBlueprintStringFromInput
    end
  end
  do
    local source = host.C_HousingCatalog
    if source then
      local target = {}
      api.housingCatalog = target
      target.createCatalogSearcher = source.CreateCatalogSearcher
      target.deletePreviewCartDecor = source.DeletePreviewCartDecor
      target.destroyEntry = source.DestroyEntry
      target.getAllFilterTagGroups = source.GetAllFilterTagGroups
      target.getAllVariantInfosForEntry = source.GetAllVariantInfosForEntry
      target.getBundleInfo = source.GetBundleInfo
      target.getCartSizeLimit = source.GetCartSizeLimit
      target.getCatalogCategoryAndSubcategoryNames = source.GetCatalogCategoryAndSubcategoryNames
      target.getCatalogCategoryInfo = source.GetCatalogCategoryInfo
      target.getCatalogEntryInfo = source.GetCatalogEntryInfo
      target.getCatalogEntryInfoByItem = source.GetCatalogEntryInfoByItem
      target.getCatalogEntryInfoByRecordID = source.GetCatalogEntryInfoByRecordID
      target.getCatalogEntryRefundTimeStampByRecordID =
        source.GetCatalogEntryRefundTimeStampByRecordID
      target.getCatalogEntryVariantInfo = source.GetCatalogEntryVariantInfo
      target.getCatalogSubcategoryInfo = source.GetCatalogSubcategoryInfo
      target.getDecorMaxOwnedCount = source.GetDecorMaxOwnedCount
      target.getDecorTotalOwnedCount = source.GetDecorTotalOwnedCount
      target.getDestroyableInstanceCount = source.GetDestroyableInstanceCount
      target.getFeaturedBundles = source.GetFeaturedBundles
      target.getFeaturedSmallProducts = source.GetFeaturedSmallProducts
      target.getMarketInfoForDecor = source.GetMarketInfoForDecor
      target.hasFeaturedEntries = source.HasFeaturedEntries
      target.housingMarketActionAddToCart = source.HousingMarketActionAddToCart
      target.housingMarketActionClearCart = source.HousingMarketActionClearCart
      target.housingMarketActionRemoveFromCart = source.HousingMarketActionRemoveFromCart
      target.housingMarketActionViewBundle = source.HousingMarketActionViewBundle
      target.housingMarketActionViewInStore = source.HousingMarketActionViewInStore
      target.isPreviewCartItemShown = source.IsPreviewCartItemShown
      target.promotePreviewDecor = source.PromotePreviewDecor
      target.requestHousingMarketInfoRefresh = source.RequestHousingMarketInfoRefresh
      target.requestHousingMarketRefundInfo = source.RequestHousingMarketRefundInfo
      target.searchCatalogCategories = source.SearchCatalogCategories
      target.searchCatalogSubcategories = source.SearchCatalogSubcategories
      target.setPreviewCartItemShown = source.SetPreviewCartItemShown
    end
  end
  do
    local source = host.C_HousingCleanupMode
    if source then
      local target = {}
      api.housingCleanupMode = target
      target.getHoveredDecorInfo = source.GetHoveredDecorInfo
      target.isHoveringDecor = source.IsHoveringDecor
      target.removeSelectedDecor = source.RemoveSelectedDecor
    end
  end
  do
    local source = host.C_HousingCustomizeMode
    if source then
      local target = {}
      api.housingCustomizeMode = target
      target.applyDyeToSelectedDecor = source.ApplyDyeToSelectedDecor
      target.applyPetToSelectedDecor = source.ApplyPetToSelectedDecor
      target.applyThemeToRoom = source.ApplyThemeToRoom
      target.applyThemeToSelectedRoomComponent = source.ApplyThemeToSelectedRoomComponent
      target.applyWallpaperToAllWalls = source.ApplyWallpaperToAllWalls
      target.applyWallpaperToSelectedRoomComponent = source.ApplyWallpaperToSelectedRoomComponent
      target.cancelActiveEditing = source.CancelActiveEditing
      target.clearDyesForSelectedDecor = source.ClearDyesForSelectedDecor
      target.clearTargetRoomComponent = source.ClearTargetRoomComponent
      target.commitDyesForSelectedDecor = source.CommitDyesForSelectedDecor
      target.getHoveredDecorInfo = source.GetHoveredDecorInfo
      target.getHoveredRoomComponentInfo = source.GetHoveredRoomComponentInfo
      target.getNumDyesToRemoveOnSelectedDecor = source.GetNumDyesToRemoveOnSelectedDecor
      target.getNumDyesToSpendOnSelectedDecor = source.GetNumDyesToSpendOnSelectedDecor
      target.getPreviewDyesOnSelectedDecor = source.GetPreviewDyesOnSelectedDecor
      target.getRecentlyUsedDyes = source.GetRecentlyUsedDyes
      target.getRecentlyUsedThemeSets = source.GetRecentlyUsedThemeSets
      target.getRecentlyUsedWallpapers = source.GetRecentlyUsedWallpapers
      target.getSelectedDecorInfo = source.GetSelectedDecorInfo
      target.getSelectedDecorPetInfo = source.GetSelectedDecorPetInfo
      target.getSelectedRoomComponentInfo = source.GetSelectedRoomComponentInfo
      target.getThemeSetInfo = source.GetThemeSetInfo
      target.getWallpapersForRoomComponentType = source.GetWallpapersForRoomComponentType
      target.isDecorSelected = source.IsDecorSelected
      target.isHouseExteriorDoorHovered = source.IsHouseExteriorDoorHovered
      target.isHoveringDecor = source.IsHoveringDecor
      target.isHoveringRoomComponent = source.IsHoveringRoomComponent
      target.isRoomComponentSelected = source.IsRoomComponentSelected
      target.roomComponentSupportsVariant = source.RoomComponentSupportsVariant
      target.roomConnectionSupportsDoorType = source.RoomConnectionSupportsDoorType
      target.setRoomComponentCeilingType = source.SetRoomComponentCeilingType
      target.setRoomComponentDoorType = source.SetRoomComponentDoorType
    end
  end
  do
    local source = host.C_HousingDecor
    if source then
      local target = {}
      api.housingDecor = target
      target.anyDecorPlacedInRoom = source.AnyDecorPlacedInRoom
      target.cancelActiveEditing = source.CancelActiveEditing
      target.commitDecorMovement = source.CommitDecorMovement
      target.enterPreviewState = source.EnterPreviewState
      target.exitPreviewState = source.ExitPreviewState
      target.getAllMaxPlacementBudgets = source.GetAllMaxPlacementBudgets
      target.getAllPlacedDecor = source.GetAllPlacedDecor
      target.getAllSpentPlacementBudgets = source.GetAllSpentPlacementBudgets
      target.getDecorAssignedPetName = source.GetDecorAssignedPetName
      target.getDecorCanAttachPet = source.GetDecorCanAttachPet
      target.getDecorHyperlink = source.GetDecorHyperlink
      target.getDecorIcon = source.GetDecorIcon
      target.getDecorInstanceInfoForGUID = source.GetDecorInstanceInfoForGUID
      target.getDecorName = source.GetDecorName
      target.getHoveredDecorInfo = source.GetHoveredDecorInfo
      target.getMaxPetPlacementBudget = source.GetMaxPetPlacementBudget
      target.getMaxPlacementBudget = source.GetMaxPlacementBudget
      target.getNumDecorPlaced = source.GetNumDecorPlaced
      target.getNumPreviewDecor = source.GetNumPreviewDecor
      target.getSelectedDecorInfo = source.GetSelectedDecorInfo
      target.getSpentPetPlacementBudget = source.GetSpentPetPlacementBudget
      target.getSpentPlacementBudget = source.GetSpentPlacementBudget
      target.hasMaxPlacementBudget = source.HasMaxPlacementBudget
      target.isDecorSelected = source.IsDecorSelected
      target.isGridVisible = source.IsGridVisible
      target.isHouseExteriorDoorHovered = source.IsHouseExteriorDoorHovered
      target.isHouseExteriorHovered = source.IsHouseExteriorHovered
      target.isHoveringDecor = source.IsHoveringDecor
      target.isModeDisabledForPreviewState = source.IsModeDisabledForPreviewState
      target.isPreviewState = source.IsPreviewState
      target.removePlacedDecorEntry = source.RemovePlacedDecorEntry
      target.removeSelectedDecor = source.RemoveSelectedDecor
      target.setGridVisible = source.SetGridVisible
      target.setPlacedDecorEntryHovered = source.SetPlacedDecorEntryHovered
      target.setPlacedDecorEntrySelected = source.SetPlacedDecorEntrySelected
    end
  end
  do
    local source = host.C_HousingExpertMode
    if source then
      local target = {}
      api.housingExpertMode = target
      target.cancelActiveEditing = source.CancelActiveEditing
      target.commitDecorMovement = source.CommitDecorMovement
      target.commitHouseExteriorPosition = source.CommitHouseExteriorPosition
      target.getHoveredDecorInfo = source.GetHoveredDecorInfo
      target.getPrecisionSubmode = source.GetPrecisionSubmode
      target.getPrecisionSubmodeRestriction = source.GetPrecisionSubmodeRestriction
      target.getSelectedDecorInfo = source.GetSelectedDecorInfo
      target.isDecorSelected = source.IsDecorSelected
      target.isGridVisible = source.IsGridVisible
      target.isHouseExteriorHovered = source.IsHouseExteriorHovered
      target.isHouseExteriorSelected = source.IsHouseExteriorSelected
      target.isHoveringDecor = source.IsHoveringDecor
      target.removeSelectedDecor = source.RemoveSelectedDecor
      target.resetPrecisionChanges = source.ResetPrecisionChanges
      target.selectNextRotationAxis = source.SelectNextRotationAxis
      target.setGridVisible = source.SetGridVisible
      target.setPrecisionIncrementingActive = source.SetPrecisionIncrementingActive
      target.setPrecisionSubmode = source.SetPrecisionSubmode
    end
  end
  do
    local source = host.C_HousingInspectMode
    if source then
      local target = {}
      api.housingInspectMode = target
      target.enterInspectMode = source.EnterInspectMode
      target.exitInspectMode = source.ExitInspectMode
      target.getHoveredDecorGUID = source.GetHoveredDecorGUID
      target.isHoveringDecor = source.IsHoveringDecor
      target.isInInspectMode = source.IsInInspectMode
    end
  end
  do
    local source = host.C_HousingLayout
    if source then
      local target = {}
      api.housingLayout = target
      target.anyRoomsOnFloor = source.AnyRoomsOnFloor
      target.canSetViewedFloor = source.CanSetViewedFloor
      target.cancelActiveLayoutEditing = source.CancelActiveLayoutEditing
      target.confirmStairChoice = source.ConfirmStairChoice
      target.deselectFloorplan = source.DeselectFloorplan
      target.deselectRoomOrDoor = source.DeselectRoomOrDoor
      target.getBaseRoomFloor = source.GetBaseRoomFloor
      target.getHighestOccupiedFloorIndex = source.GetHighestOccupiedFloorIndex
      target.getLowestOccupiedFloorIndex = source.GetLowestOccupiedFloorIndex
      target.getNumActiveRooms = source.GetNumActiveRooms
      target.getRoomPlacementBudget = source.GetRoomPlacementBudget
      target.getRoomPlayerIsIn = source.GetRoomPlayerIsIn
      target.getSelectedBlueprintFloorplan = source.GetSelectedBlueprintFloorplan
      target.getSelectedDoor = source.GetSelectedDoor
      target.getSelectedFloorplan = source.GetSelectedFloorplan
      target.getSelectedRoom = source.GetSelectedRoom
      target.getSelectedStairwellRoomCount = source.GetSelectedStairwellRoomCount
      target.getSpentPlacementBudget = source.GetSpentPlacementBudget
      target.getViewedFloor = source.GetViewedFloor
      target.hasAnySelections = source.HasAnySelections
      target.hasRoomPlacementBudget = source.HasRoomPlacementBudget
      target.hasSelectedBlueprintFloorplan = source.HasSelectedBlueprintFloorplan
      target.hasSelectedDoor = source.HasSelectedDoor
      target.hasSelectedFloorplan = source.HasSelectedFloorplan
      target.hasSelectedRoom = source.HasSelectedRoom
      target.hasStairs = source.HasStairs
      target.hasValidConnection = source.HasValidConnection
      target.isBaseRoom = source.IsBaseRoom
      target.isDraggingRoom = source.IsDraggingRoom
      target.moveDraggedRoom = source.MoveDraggedRoom
      target.moveLayoutCamera = source.MoveLayoutCamera
      target.removeRoom = source.RemoveRoom
      target.roomHasStairs = source.RoomHasStairs
      target.rotateFocusedRoom = source.RotateFocusedRoom
      target.rotateRoom = source.RotateRoom
      target.selectFloorplan = source.SelectFloorplan
      target.setViewedFloor = source.SetViewedFloor
      target.startDrag = source.StartDrag
      target.stopDrag = source.StopDrag
      target.stopDraggingRoom = source.StopDraggingRoom
      target.zoomLayoutCamera = source.ZoomLayoutCamera
    end
  end
  do
    local source = host.C_HousingNeighborhood
    if source then
      local target = {}
      api.housingNeighborhood = target
      target.canReturnAfterVisitingHouse = source.CanReturnAfterVisitingHouse
      target.cancelInviteToNeighborhood = source.CancelInviteToNeighborhood
      target.demoteToResident = source.DemoteToResident
      target.getCornerstoneHouseInfo = source.GetCornerstoneHouseInfo
      target.getCornerstoneNeighborhoodInfo = source.GetCornerstoneNeighborhoodInfo
      target.getCornerstonePurchaseMode = source.GetCornerstonePurchaseMode
      target.getCurrentNeighborhoodTextureSuffix = source.GetCurrentNeighborhoodTextureSuffix
      target.getDiscountedMovePrice = source.GetDiscountedMovePrice
      target.getMoveCooldownTime = source.GetMoveCooldownTime
      target.getNeighborhoodMapData = source.GetNeighborhoodMapData
      target.getNeighborhoodName = source.GetNeighborhoodName
      target.getNeighborhoodPlotName = source.GetNeighborhoodPlotName
      target.getPreviousHouseIdentifier = source.GetPreviousHouseIdentifier
      target.hasPermissionToPurchase = source.HasPermissionToPurchase
      target.invitePlayerToNeighborhood = source.InvitePlayerToNeighborhood
      target.isNeighborhoodManager = source.IsNeighborhoodManager
      target.isNeighborhoodOwner = source.IsNeighborhoodOwner
      target.isPlayerInOtherPlayersPlot = source.IsPlayerInOtherPlayersPlot
      target.isPlotAvailableForPurchase = source.IsPlotAvailableForPurchase
      target.isPlotOwnedByPlayer = source.IsPlotOwnedByPlayer
      target.onBulletinBoardClosed = source.OnBulletinBoardClosed
      target.onCornerstoneClosed = source.OnCornerstoneClosed
      target.promoteToManager = source.PromoteToManager
      target.requestNeighborhoodInfo = source.RequestNeighborhoodInfo
      target.requestNeighborhoodRoster = source.RequestNeighborhoodRoster
      target.requestPendingNeighborhoodInvites = source.RequestPendingNeighborhoodInvites
      target.transferNeighborhoodOwnership = source.TransferNeighborhoodOwnership
      target.tryEvictPlayer = source.TryEvictPlayer
      target.tryMoveHouse = source.TryMoveHouse
      target.tryPurchasePlot = source.TryPurchasePlot
    end
  end
  do
    local source = host.C_ImmersiveInteraction
    if source then
      local target = {}
      api.immersiveInteraction = target
      target.hasImmersiveInteraction = source.HasImmersiveInteraction
    end
  end
  do
    local source = host.C_IncomingSummon
    if source then
      local target = {}
      api.incomingSummon = target
      target.hasIncomingSummon = source.HasIncomingSummon
      target.incomingSummonStatus = source.IncomingSummonStatus
    end
  end
  do
    local target = {}
    api.input = target
    target.getCursorDelta = host.GetCursorDelta
    target.getCursorPosition = host.GetCursorPosition
    target.getMouseButtonClicked = host.GetMouseButtonClicked
    target.getMouseButtonName = host.GetMouseButtonName
    target.getMouseFoci = host.GetMouseFoci
    target.getStringFromModifiers = host.GetStringFromModifiers
    target.isAltKeyDown = host.IsAltKeyDown
    target.isControlKeyDown = host.IsControlKeyDown
    target.isKeyDown = host.IsKeyDown
    target.isLeftAltKeyDown = host.IsLeftAltKeyDown
    target.isLeftControlKeyDown = host.IsLeftControlKeyDown
    target.isLeftMetaKeyDown = host.IsLeftMetaKeyDown
    target.isLeftShiftKeyDown = host.IsLeftShiftKeyDown
    target.isMetaKeyDown = host.IsMetaKeyDown
    target.isModifierKeyDown = host.IsModifierKeyDown
    target.isMouseButtonDown = host.IsMouseButtonDown
    target.isRightAltKeyDown = host.IsRightAltKeyDown
    target.isRightControlKeyDown = host.IsRightControlKeyDown
    target.isRightMetaKeyDown = host.IsRightMetaKeyDown
    target.isRightShiftKeyDown = host.IsRightShiftKeyDown
    target.isShiftKeyDown = host.IsShiftKeyDown
    target.isUsingGamepad = host.IsUsingGamepad
    target.isUsingMouse = host.IsUsingMouse
    target.makeModifiers = host.MakeModifiers
    target.setCursorPosition = host.SetCursorPosition
    target.simulateMouseClick = host.SimulateMouseClick
    target.simulateMouseDown = host.SimulateMouseDown
    target.simulateMouseUp = host.SimulateMouseUp
    target.simulateMouseWheel = host.SimulateMouseWheel
  end
  do
    local target = {}
    api.instance = target
    target.canChangePlayerDifficulty = host.CanChangePlayerDifficulty
    target.canMapChangeDifficulty = host.CanMapChangeDifficulty
    target.canShowResetInstances = host.CanShowResetInstances
    target.getBaseDifficultyID = host.GetBaseDifficultyID
    target.getDifficultyInfo = host.GetDifficultyInfo
    target.getDungeonDifficultyID = host.GetDungeonDifficultyID
    target.getInstanceBootTimeRemaining = host.GetInstanceBootTimeRemaining
    target.getInstanceInfo = host.GetInstanceInfo
    target.getInstanceLockTimeRemaining = host.GetInstanceLockTimeRemaining
    target.getInstanceLockTimeRemainingEncounter = host.GetInstanceLockTimeRemainingEncounter
    target.getLegacyRaidDifficultyID = host.GetLegacyRaidDifficultyID
    target.getRaidDifficultyID = host.GetRaidDifficultyID
    target.isInInstance = host.IsInInstance
    target.isLegacyDifficulty = host.IsLegacyDifficulty
    target.resetInstances = host.ResetInstances
    target.setDungeonDifficultyID = host.SetDungeonDifficultyID
    target.setLegacyRaidDifficultyID = host.SetLegacyRaidDifficultyID
    target.setRaidDifficultyID = host.SetRaidDifficultyID
  end
  do
    local source = host.C_InstanceEncounter
    if source then
      local target = {}
      api.instanceEncounter = target
      target.isEncounterInProgress = source.IsEncounterInProgress
      target.isEncounterLimitingResurrections = source.IsEncounterLimitingResurrections
      target.isEncounterSuppressingRelease = source.IsEncounterSuppressingRelease
      target.shouldShowTimelineForEncounter = source.ShouldShowTimelineForEncounter
    end
  end
  do
    local source = host.C_InstanceLeaver
    if source then
      local target = {}
      api.instanceLeaver = target
      target.isPlayerLeaver = source.IsPlayerLeaver
    end
  end
  do
    local source = host.C_InterfaceFileManifest
    if source then
      local target = {}
      api.interfaceFileManifest = target
      target.getInterfaceArtFiles = source.GetInterfaceArtFiles
    end
  end
  do
    local source = host.C_InvasionInfo
    if source then
      local target = {}
      api.invasionInfo = target
      target.areInvasionsAvailable = source.AreInvasionsAvailable
      target.getInvasionForUiMapID = source.GetInvasionForUiMapID
      target.getInvasionInfo = source.GetInvasionInfo
      target.getInvasionTimeLeft = source.GetInvasionTimeLeft
    end
  end
  do
    local source = host.C_IslandsInfo
    if source then
      local target = {}
      api.islandsInfo = target
    end
  end
  do
    local source = host.C_IslandsQueue
    if source then
      local target = {}
      api.islandsQueue = target
      target.closeIslandsQueueScreen = source.CloseIslandsQueueScreen
      target.getIslandDifficultyInfo = source.GetIslandDifficultyInfo
      target.getIslandsMaxGroupSize = source.GetIslandsMaxGroupSize
      target.getIslandsWeeklyQuestID = source.GetIslandsWeeklyQuestID
      target.queueForIsland = source.QueueForIsland
      target.requestPreloadRewardData = source.RequestPreloadRewardData
    end
  end
  do
    local source = host.C_Item
    if source then
      local target = {}
      api.item = target
      target.actionBindsItem = source.ActionBindsItem
      target.bindEnchant = source.BindEnchant
      target.canBeRefunded = source.CanBeRefunded
      target.canItemTransmogAppearance = source.CanItemTransmogAppearance
      target.canScrapItem = source.CanScrapItem
      target.canViewItemPowers = source.CanViewItemPowers
      target.confirmBindOnUse = source.ConfirmBindOnUse
      target.confirmNoRefundOnUse = source.ConfirmNoRefundOnUse
      target.confirmOnUse = source.ConfirmOnUse
      target.doesItemContainSpec = source.DoesItemContainSpec
      target.doesItemExist = source.DoesItemExist
      target.doesItemExistByID = source.DoesItemExistByID
      target.doesItemMatchBonusTreeReplacement = source.DoesItemMatchBonusTreeReplacement
      target.doesItemMatchSpellItemCondition = source.DoesItemMatchSpellItemCondition
      target.doesItemMatchTargetEnchantingSpell = source.DoesItemMatchTargetEnchantingSpell
      target.doesItemMatchTrackJump = source.DoesItemMatchTrackJump
      target.dropItemOnUnit = source.DropItemOnUnit
      target.endBoundTradeable = source.EndBoundTradeable
      target.endRefund = source.EndRefund
      target.equipItemByName = source.EquipItemByName
      target.getAppliedItemTransmogInfo = source.GetAppliedItemTransmogInfo
      target.getBaseItemTransmogInfo = source.GetBaseItemTransmogInfo
      target.getCurrentItemLevel = source.GetCurrentItemLevel
      target.getCurrentItemTransmogInfo = source.GetCurrentItemTransmogInfo
      target.getDelvePreviewItemLink = source.GetDelvePreviewItemLink
      target.getDelvePreviewItemQuality = source.GetDelvePreviewItemQuality
      target.getDetailedItemLevelInfo = source.GetDetailedItemLevelInfo
      target.getFirstTriggeredSpellForItem = source.GetFirstTriggeredSpellForItem
      target.getItemChildInfo = source.GetItemChildInfo
      target.getItemClassInfo = source.GetItemClassInfo
      target.getItemConversionOutputIcon = source.GetItemConversionOutputIcon
      target.getItemCooldown = source.GetItemCooldown
      target.getItemCount = source.GetItemCount
      target.getItemCreationContext = source.GetItemCreationContext
      target.getItemFamily = source.GetItemFamily
      target.getItemGUID = source.GetItemGUID
      target.getItemGem = source.GetItemGem
      target.getItemGemID = source.GetItemGemID
      target.getItemID = source.GetItemID
      target.getItemIDByGUID = source.GetItemIDByGUID
      target.getItemIDForItemInfo = source.GetItemIDForItemInfo
      target.getItemIcon = source.GetItemIcon
      target.getItemIconByID = source.GetItemIconByID
      target.getItemInfo = source.GetItemInfo
      target.getItemInfoInstant = source.GetItemInfoInstant
      target.getItemInventorySlotInfo = source.GetItemInventorySlotInfo
      target.getItemInventorySlotKey = source.GetItemInventorySlotKey
      target.getItemInventoryType = source.GetItemInventoryType
      target.getItemInventoryTypeByID = source.GetItemInventoryTypeByID
      target.getItemLearnTransmogSet = source.GetItemLearnTransmogSet
      target.getItemLink = source.GetItemLink
      target.getItemLinkByGUID = source.GetItemLinkByGUID
      target.getItemLocation = source.GetItemLocation
      target.getItemMaxStackSize = source.GetItemMaxStackSize
      target.getItemMaxStackSizeByID = source.GetItemMaxStackSizeByID
      target.getItemName = source.GetItemName
      target.getItemNameByID = source.GetItemNameByID
      target.getItemNumAddedSockets = source.GetItemNumAddedSockets
      target.getItemNumSockets = source.GetItemNumSockets
      target.getItemQuality = source.GetItemQuality
      target.getItemQualityByID = source.GetItemQualityByID
      target.getItemQualityColor = source.GetItemQualityColor
      target.getItemSetInfo = source.GetItemSetInfo
      target.getItemSpecInfo = source.GetItemSpecInfo
      target.getItemSpell = source.GetItemSpell
      target.getItemStatDelta = source.GetItemStatDelta
      target.getItemStats = source.GetItemStats
      target.getItemSubClassInfo = source.GetItemSubClassInfo
      target.getItemUniqueness = source.GetItemUniqueness
      target.getItemUniquenessByID = source.GetItemUniquenessByID
      target.getItemUpgradeInfo = source.GetItemUpgradeInfo
      target.getLimitedCurrencyItemInfo = source.GetLimitedCurrencyItemInfo
      target.getSetBonusesForSpecializationByItemID = source.GetSetBonusesForSpecializationByItemID
      target.getStackCount = source.GetStackCount
      target.isAnimaItemByID = source.IsAnimaItemByID
      target.isArtifactPowerItem = source.IsArtifactPowerItem
      target.isBound = source.IsBound
      target.isBoundToAccountUntilEquip = source.IsBoundToAccountUntilEquip
      target.isConsumableItem = source.IsConsumableItem
      target.isCorruptedItem = source.IsCorruptedItem
      target.isCosmeticItem = source.IsCosmeticItem
      target.isCurioItem = source.IsCurioItem
      target.isCurrentItem = source.IsCurrentItem
      target.isDecorItem = source.IsDecorItem
      target.isDressableItemByID = source.IsDressableItemByID
      target.isEquippableItem = source.IsEquippableItem
      target.isEquippedItem = source.IsEquippedItem
      target.isEquippedItemType = source.IsEquippedItemType
      target.isHarmfulItem = source.IsHarmfulItem
      target.isHelpfulItem = source.IsHelpfulItem
      target.isItemBindToAccount = source.IsItemBindToAccount
      target.isItemBindToAccountUntilEquip = source.IsItemBindToAccountUntilEquip
      target.isItemConduit = source.IsItemConduit
      target.isItemConvertibleAndValidForPlayer = source.IsItemConvertibleAndValidForPlayer
      target.isItemCorrupted = source.IsItemCorrupted
      target.isItemCorruptionRelated = source.IsItemCorruptionRelated
      target.isItemCorruptionResistant = source.IsItemCorruptionResistant
      target.isItemDataCached = source.IsItemDataCached
      target.isItemDataCachedByID = source.IsItemDataCachedByID
      target.isItemGUIDInInventory = source.IsItemGUIDInInventory
      target.isItemInRange = source.IsItemInRange
      target.isItemKeystoneByID = source.IsItemKeystoneByID
      target.isItemSpecificToPlayerClass = source.IsItemSpecificToPlayerClass
      target.isLocked = source.IsLocked
      target.isRelicItem = source.IsRelicItem
      target.isUsableItem = source.IsUsableItem
      target.itemHasRange = source.ItemHasRange
      target.lockItem = source.LockItem
      target.lockItemByGUID = source.LockItemByGUID
      target.pickupItem = source.PickupItem
      target.replaceEnchant = source.ReplaceEnchant
      target.replaceTradeEnchant = source.ReplaceTradeEnchant
      target.replaceTradeskillEnchant = source.ReplaceTradeskillEnchant
      target.requestLoadItemData = source.RequestLoadItemData
      target.requestLoadItemDataByID = source.RequestLoadItemDataByID
      target.unlockItem = source.UnlockItem
      target.unlockItemByGUID = source.UnlockItemByGUID
      target.useItemByName = source.UseItemByName
    end
  end
  do
    local source = host.C_ItemInteraction
    if source then
      local target = {}
      api.itemInteraction = target
      target.clearPendingItem = source.ClearPendingItem
      target.closeUI = source.CloseUI
      target.getChargeInfo = source.GetChargeInfo
      target.getItemConversionCurrencyCost = source.GetItemConversionCurrencyCost
      target.getItemInteractionInfo = source.GetItemInteractionInfo
      target.getItemInteractionSpellId = source.GetItemInteractionSpellId
      target.initializeFrame = source.InitializeFrame
      target.performItemInteraction = source.PerformItemInteraction
      target.reset = source.Reset
      target.setPendingItem = source.SetPendingItem
    end
  end
  do
    local source = host.C_ItemSocketInfo
    if source then
      local target = {}
      api.itemSocketInfo = target
      target.acceptSockets = source.AcceptSockets
      target.clickSocketButton = source.ClickSocketButton
      target.closeSocketInfo = source.CloseSocketInfo
      target.completeSocketing = source.CompleteSocketing
      target.getCurrUIType = source.GetCurrUIType
      target.getExistingSocketInfo = source.GetExistingSocketInfo
      target.getExistingSocketLink = source.GetExistingSocketLink
      target.getNewSocketInfo = source.GetNewSocketInfo
      target.getNewSocketLink = source.GetNewSocketLink
      target.getNumSockets = source.GetNumSockets
      target.getSocketItemBoundTradeable = source.GetSocketItemBoundTradeable
      target.getSocketItemInfo = source.GetSocketItemInfo
      target.getSocketItemRefundable = source.GetSocketItemRefundable
      target.getSocketTypes = source.GetSocketTypes
      target.hasBoundGemProposed = source.HasBoundGemProposed
      target.isArtifactRelicItem = source.IsArtifactRelicItem
    end
  end
  do
    local source = host.C_ItemText
    if source then
      local target = {}
      api.itemText = target
    end
  end
  do
    local source = host.C_ItemUpgrade
    if source then
      local target = {}
      api.itemUpgrade = target
      target.canUpgradeItem = source.CanUpgradeItem
      target.clearItemUpgrade = source.ClearItemUpgrade
      target.closeItemUpgrade = source.CloseItemUpgrade
      target.getHighWatermarkForItem = source.GetHighWatermarkForItem
      target.getHighWatermarkForSlot = source.GetHighWatermarkForSlot
      target.getHighWatermarkSlotForItem = source.GetHighWatermarkSlotForItem
      target.getItemHyperlink = source.GetItemHyperlink
      target.getItemUpgradeCurrentLevel = source.GetItemUpgradeCurrentLevel
      target.getItemUpgradeEffect = source.GetItemUpgradeEffect
      target.getItemUpgradeItemInfo = source.GetItemUpgradeItemInfo
      target.getItemUpgradePvpItemLevelDeltaValues = source.GetItemUpgradePvpItemLevelDeltaValues
      target.getNumItemUpgradeEffects = source.GetNumItemUpgradeEffects
      target.isItemBound = source.IsItemBound
      target.setItemUpgradeFromCursorItem = source.SetItemUpgradeFromCursorItem
      target.setItemUpgradeFromLocation = source.SetItemUpgradeFromLocation
      target.upgradeItem = source.UpgradeItem
    end
  end
  do
    local source = host.C_KeyBindings
    if source then
      local target = {}
      api.keyBindings = target
      target.activateBindingContext = source.ActivateBindingContext
      target.deactivateBindingContext = source.DeactivateBindingContext
      target.getBindingByKey = source.GetBindingByKey
      target.getBindingContextForAction = source.GetBindingContextForAction
      target.getBindingIndex = source.GetBindingIndex
      target.getCustomBindingType = source.GetCustomBindingType
      target.getSearchTagsForAction = source.GetSearchTagsForAction
      target.getTurnStrafeStyle = source.GetTurnStrafeStyle
      target.isBindingContextActive = source.IsBindingContextActive
      target.setTurnStrafeStyle = source.SetTurnStrafeStyle
      target.updateTurnStrafeBindingsForCharacter = source.UpdateTurnStrafeBindingsForCharacter
    end
  end
  do
    local source = host.C_LegendaryCrafting
    if source then
      local target = {}
      api.legendaryCrafting = target
      target.closeRuneforgeInteraction = source.CloseRuneforgeInteraction
      target.craftRuneforgeLegendary = source.CraftRuneforgeLegendary
      target.getRuneforgeItemPreviewInfo = source.GetRuneforgeItemPreviewInfo
      target.getRuneforgeLegendaryComponentInfo = source.GetRuneforgeLegendaryComponentInfo
      target.getRuneforgeLegendaryCost = source.GetRuneforgeLegendaryCost
      target.getRuneforgeLegendaryCraftSpellID = source.GetRuneforgeLegendaryCraftSpellID
      target.getRuneforgeLegendaryCurrencies = source.GetRuneforgeLegendaryCurrencies
      target.getRuneforgeLegendaryUpgradeCost = source.GetRuneforgeLegendaryUpgradeCost
      target.getRuneforgeModifierInfo = source.GetRuneforgeModifierInfo
      target.getRuneforgeModifiers = source.GetRuneforgeModifiers
      target.getRuneforgePowerInfo = source.GetRuneforgePowerInfo
      target.getRuneforgePowerSlots = source.GetRuneforgePowerSlots
      target.getRuneforgePowers = source.GetRuneforgePowers
      target.getRuneforgePowersByClassSpecAndCovenant =
        source.GetRuneforgePowersByClassSpecAndCovenant
      target.isRuneforgeLegendary = source.IsRuneforgeLegendary
      target.isRuneforgeLegendaryMaxLevel = source.IsRuneforgeLegendaryMaxLevel
      target.isUpgradeItemValidForRuneforgeLegendary =
        source.IsUpgradeItemValidForRuneforgeLegendary
      target.isValidRuneforgeBaseItem = source.IsValidRuneforgeBaseItem
      target.makeRuneforgeCraftDescription = source.MakeRuneforgeCraftDescription
      target.upgradeRuneforgeLegendary = source.UpgradeRuneforgeLegendary
    end
  end
  do
    local source = host.C_LevelLink
    if source then
      local target = {}
      api.levelLink = target
      target.isActionLocked = source.IsActionLocked
      target.isSpellLocked = source.IsSpellLocked
    end
  end
  do
    local source = host.C_LevelSquish
    if source then
      local target = {}
      api.levelSquish = target
      target.convertFollowerLevel = source.ConvertFollowerLevel
      target.convertPlayerLevel = source.ConvertPlayerLevel
    end
  end
  do
    local source = host.C_LFGInfo
    if source then
      local target = {}
      api.lfgInfo = target
      target.areCrossFactionGroupQueuesAllowed = source.AreCrossFactionGroupQueuesAllowed
      target.canPlayerUseGroupFinder = source.CanPlayerUseGroupFinder
      target.canPlayerUseLFD = source.CanPlayerUseLFD
      target.canPlayerUseLFR = source.CanPlayerUseLFR
      target.canPlayerUsePVP = source.CanPlayerUsePVP
      target.canPlayerUsePremadeGroup = source.CanPlayerUsePremadeGroup
      target.canPlayerUseScenarioFinder = source.CanPlayerUseScenarioFinder
      target.confirmLfgExpandSearch = source.ConfirmLfgExpandSearch
      target.doesActivePartyMeetPremadeLaunchCount = source.DoesActivePartyMeetPremadeLaunchCount
      target.doesCrossFactionQueueRequireFullPremade =
        source.DoesCrossFactionQueueRequireFullPremade
      target.getAllEntriesForCategory = source.GetAllEntriesForCategory
      target.getDungeonInfo = source.GetDungeonInfo
      target.getLFDLockStates = source.GetLFDLockStates
      target.getLevelUpInstances = source.GetLevelUpInstances
      target.getRoleCheckDifficultyDetails = source.GetRoleCheckDifficultyDetails
      target.hideNameFromUI = source.HideNameFromUI
      target.isGroupFinderEnabled = source.IsGroupFinderEnabled
      target.isInLFGFollowerDungeon = source.IsInLFGFollowerDungeon
      target.isInMatchmadeRaidWithoutRoleRequirements =
        source.IsInMatchmadeRaidWithoutRoleRequirements
      target.isLFDEnabled = source.IsLFDEnabled
      target.isLFGFollowerDungeon = source.IsLFGFollowerDungeon
      target.isLFREnabled = source.IsLFREnabled
    end
  end
  do
    local source = host.C_LFGList
    if source then
      local target = {}
      api.lfgList = target
      target.canActiveEntryUseAutoAccept = source.CanActiveEntryUseAutoAccept
      target.canCreateQuestGroup = source.CanCreateQuestGroup
      target.canCreateScenarioGroup = source.CanCreateScenarioGroup
      target.clearApplicationTextFields = source.ClearApplicationTextFields
      target.clearCreationTextFields = source.ClearCreationTextFields
      target.clearSearchTextFields = source.ClearSearchTextFields
      target.confirmCensoredActiveEntry = source.ConfirmCensoredActiveEntry
      target.copyActiveEntryInfoToCreationFields = source.CopyActiveEntryInfoToCreationFields
      target.createListing = source.CreateListing
      target.createScenarioListing = source.CreateScenarioListing
      target.doesCensoredTextMatch = source.DoesCensoredTextMatch
      target.doesEntryTitleMatchPrebuiltTitle = source.DoesEntryTitleMatchPrebuiltTitle
      target.getActiveEntryInfo = source.GetActiveEntryInfo
      target.getActivityFullName = source.GetActivityFullName
      target.getActivityGroupInfo = source.GetActivityGroupInfo
      target.getActivityInfoTable = source.GetActivityInfoTable
      target.getAdvancedFilter = source.GetAdvancedFilter
      target.getApplicantBestDungeonScore = source.GetApplicantBestDungeonScore
      target.getApplicantDungeonScoreForListing = source.GetApplicantDungeonScoreForListing
      target.getApplicantInfo = source.GetApplicantInfo
      target.getApplicantPvpRatingInfoForListing = source.GetApplicantPvpRatingInfoForListing
      target.getAvailableActivityGroups = source.GetAvailableActivityGroups
      target.getFilteredSearchResults = source.GetFilteredSearchResults
      target.getGroupLeaverCountsByRole = source.GetGroupLeaverCountsByRole
      target.getKeystoneForActivity = source.GetKeystoneForActivity
      target.getLfgCategoryInfo = source.GetLfgCategoryInfo
      target.getOwnedKeystoneActivityAndGroupAndLevel =
        source.GetOwnedKeystoneActivityAndGroupAndLevel
      target.getPlaystyleString = source.GetPlaystyleString
      target.getPremadeGroupFinderStyle = source.GetPremadeGroupFinderStyle
      target.getSearchResultInfo = source.GetSearchResultInfo
      target.getSearchResultLeaderInfo = source.GetSearchResultLeaderInfo
      target.getSearchResultPlayerInfo = source.GetSearchResultPlayerInfo
      target.getSearchResults = source.GetSearchResults
      target.hasActiveEntryInfo = source.HasActiveEntryInfo
      target.hasSearchResultInfo = source.HasSearchResultInfo
      target.isCensoredActiveEntryUnresolved = source.IsCensoredActiveEntryUnresolved
      target.isPlayerAuthenticatedForLFG = source.IsPlayerAuthenticatedForLFG
      target.isPlayerValidForEndgameFieldEdits = source.IsPlayerValidForEndgameFieldEdits
      target.isPremadeGroupFinderEnabled = source.IsPremadeGroupFinderEnabled
      target.listingUsesEndgameEditRestrictions = source.ListingUsesEndgameEditRestrictions
      target.reportGroupAsAdvertisement = source.ReportGroupAsAdvertisement
      target.revealCensoredActiveEntry = source.RevealCensoredActiveEntry
      target.revealCensoredSearchResult = source.RevealCensoredSearchResult
      target.saveAdvancedFilter = source.SaveAdvancedFilter
      target.search = source.Search
      target.setEntryTitle = source.SetEntryTitle
      target.setSearchToActivity = source.SetSearchToActivity
      target.setSearchToQuestID = source.SetSearchToQuestID
      target.setSearchToScenarioID = source.SetSearchToScenarioID
      target.updateListing = source.UpdateListing
      target.validateRequiredDungeonScore = source.ValidateRequiredDungeonScore
      target.validateRequiredPvpRatingForActivity = source.ValidateRequiredPvpRatingForActivity
    end
  end
  do
    local source = host.C_LimitedInput
    if source then
      local target = {}
      api.limitedInput = target
      target.limitedInputAllowed = source.LimitedInputAllowed
    end
  end
  do
    local source = host.C_LiveEvent
    if source then
      local target = {}
      api.liveEvent = target
      target.onLiveEventBannerClicked = source.OnLiveEventBannerClicked
      target.onLiveEventPopupClicked = source.OnLiveEventPopupClicked
    end
  end
  do
    local source = host.C_LoadingScreen
    if source then
      local target = {}
      api.loadingScreen = target
    end
  end
  do
    local source = host.C_LobbyMatchmakerInfo
    if source then
      local target = {}
      api.lobbyMatchmakerInfo = target
      target.abandonQueue = source.AbandonQueue
      target.enterQueue = source.EnterQueue
      target.getCurrQueuePlaylistEntry = source.GetCurrQueuePlaylistEntry
      target.getCurrQueueState = source.GetCurrQueueState
      target.getQueueFromMainlineEnabled = source.GetQueueFromMainlineEnabled
      target.getQueueStartTime = source.GetQueueStartTime
      target.isInQueue = source.IsInQueue
      target.respondToQueuePop = source.RespondToQueuePop
    end
  end
  do
    local target = {}
    api.locale = target
    target.getAvailableLocaleInfo = host.GetAvailableLocaleInfo
    target.getAvailableLocales = host.GetAvailableLocales
    target.getCurrentRegion = host.GetCurrentRegion
    target.getLocale = host.GetLocale
    target.getOSLocale = host.GetOSLocale
  end
  do
    local target = {}
    api.localization = target
    target.abbreviateLargeNumbers = host.AbbreviateLargeNumbers
    target.abbreviateNumbers = host.AbbreviateNumbers
    target.breakUpLargeNumbers = host.BreakUpLargeNumbers
    target.caseAccentInsensitiveParse = host.CaseAccentInsensitiveParse
    target.createAbbreviateConfig = host.CreateAbbreviateConfig
    target.declineName = host.DeclineName
    target.getNumDeclensionSets = host.GetNumDeclensionSets
    target.isEuropeanNumbers = host.IsEuropeanNumbers
    target.localizedClassList = host.LocalizedClassList
    target.setEuropeanNumbers = host.SetEuropeanNumbers
    do
      local elsewhere = host.C_StringUtil
      if elsewhere then
        target.getDefaultAbbreviationBreakpoints = elsewhere.GetDefaultAbbreviationBreakpoints
      end
    end
  end
  do
    local source = host.C_Log
    if source then
      local target = {}
      api.log = target
      target.logErrorMessage = source.LogErrorMessage
      target.logMessage = source.LogMessage
      target.logMessageWithPriority = source.LogMessageWithPriority
      target.logWarningMessage = source.LogWarningMessage
    end
  end
  do
    local source = host.C_Loot
    if source then
      local target = {}
      api.loot = target
      target.getLootRollDuration = source.GetLootRollDuration
      target.isLegacyLootModeEnabled = source.IsLegacyLootModeEnabled
    end
  end
  do
    local source = host.C_LootHistory
    if source then
      local target = {}
      api.lootHistory = target
      target.getAllEncounterInfos = source.GetAllEncounterInfos
      target.getInfoForEncounter = source.GetInfoForEncounter
      target.getLootHistoryTime = source.GetLootHistoryTime
      target.getSortedDropsForEncounter = source.GetSortedDropsForEncounter
      target.getSortedInfoForDrop = source.GetSortedInfoForDrop
    end
  end
  do
    local source = host.C_LootJournal
    if source then
      local target = {}
      api.lootJournal = target
      target.getItemSetItems = source.GetItemSetItems
      target.getItemSets = source.GetItemSets
    end
  end
  do
    local source = host.C_LoreText
    if source then
      local target = {}
      api.loreText = target
      target.requestLoreTextForCampaignID = source.RequestLoreTextForCampaignID
    end
  end
  do
    local source = host.C_LossOfControl
    if source then
      local target = {}
      api.lossOfControl = target
      target.getActiveLossOfControlData = source.GetActiveLossOfControlData
      target.getActiveLossOfControlDataByUnit = source.GetActiveLossOfControlDataByUnit
      target.getActiveLossOfControlDataCount = source.GetActiveLossOfControlDataCount
      target.getActiveLossOfControlDataCountByUnit = source.GetActiveLossOfControlDataCountByUnit
      target.getActiveLossOfControlDuration = source.GetActiveLossOfControlDuration
    end
  end
  do
    local source = host.C_MacOptions
    if source then
      local target = {}
      api.macOptions = target
      target.areOSShortcutsDisabled = source.AreOSShortcutsDisabled
      target.getGameBundleName = source.GetGameBundleName
      target.hasNewStyleInputMonitoring = source.HasNewStyleInputMonitoring
      target.isInputMonitoringEnabled = source.IsInputMonitoringEnabled
      target.isMicrophoneEnabled = source.IsMicrophoneEnabled
      target.isUniversalAccessEnabled = source.IsUniversalAccessEnabled
      target.openInputMonitoring = source.OpenInputMonitoring
      target.openMicrophoneRequestDialogue = source.OpenMicrophoneRequestDialogue
      target.openUniversalAccess = source.OpenUniversalAccess
      target.setOSShortcutsDisabled = source.SetOSShortcutsDisabled
    end
  end
  do
    local source = host.C_Macro
    if source then
      local target = {}
      api.macro = target
      target.getMacroName = source.GetMacroName
      target.getSelectedMacroIcon = source.GetSelectedMacroIcon
      target.runMacroText = source.RunMacroText
      target.setMacroExecuteLineCallback = source.SetMacroExecuteLineCallback
    end
  end
  do
    local source = host.C_Mail
    if source then
      local target = {}
      api.mail = target
      target.canCheckInbox = source.CanCheckInbox
      target.getCraftingOrderMailInfo = source.GetCraftingOrderMailInfo
      target.hasInboxMoney = source.HasInboxMoney
      target.isCommandPending = source.IsCommandPending
      target.setOpeningAll = source.SetOpeningAll
    end
  end
  do
    local source = host.C_MajorFactions
    if source then
      local target = {}
      api.majorFactions = target
      target.getCurrentRenownLevel = source.GetCurrentRenownLevel
      target.getMajorFactionData = source.GetMajorFactionData
      target.getMajorFactionIDs = source.GetMajorFactionIDs
      target.getMajorFactionRenownInfo = source.GetMajorFactionRenownInfo
      target.getRenownLevels = source.GetRenownLevels
      target.getRenownNPCFactionID = source.GetRenownNPCFactionID
      target.getRenownRewardsForLevel = source.GetRenownRewardsForLevel
      target.hasMaximumRenown = source.HasMaximumRenown
      target.isMajorFactionHiddenFromExpansionPage = source.IsMajorFactionHiddenFromExpansionPage
      target.isWeeklyRenownCapped = source.IsWeeklyRenownCapped
      target.shouldDisplayMajorFactionAsJourney = source.ShouldDisplayMajorFactionAsJourney
      target.shouldUseJourneyRewardTrack = source.ShouldUseJourneyRewardTrack
    end
  end
  do
    local source = host.C_Map
    if source then
      local target = {}
      api.map = target
      target.canSetUserWaypointOnMap = source.CanSetUserWaypointOnMap
      target.clearUserWaypoint = source.ClearUserWaypoint
      target.closeWorldMapInteraction = source.CloseWorldMapInteraction
      target.getAreaInfo = source.GetAreaInfo
      target.getBestMapForUnit = source.GetBestMapForUnit
      target.getBountySetMaps = source.GetBountySetMaps
      target.getFallbackWorldMapID = source.GetFallbackWorldMapID
      target.getMapArtBackgroundAtlas = source.GetMapArtBackgroundAtlas
      target.getMapArtHelpTextPosition = source.GetMapArtHelpTextPosition
      target.getMapArtID = source.GetMapArtID
      target.getMapArtLayerTextures = source.GetMapArtLayerTextures
      target.getMapArtLayers = source.GetMapArtLayers
      target.getMapArtZoneTextPosition = source.GetMapArtZoneTextPosition
      target.getMapBannersForMap = source.GetMapBannersForMap
      target.getMapChildrenInfo = source.GetMapChildrenInfo
      target.getMapDisplayInfo = source.GetMapDisplayInfo
      target.getMapGroupID = source.GetMapGroupID
      target.getMapGroupMembersInfo = source.GetMapGroupMembersInfo
      target.getMapHighlightInfoAtPosition = source.GetMapHighlightInfoAtPosition
      target.getMapHighlightPulseInfo = source.GetMapHighlightPulseInfo
      target.getMapInfo = source.GetMapInfo
      target.getMapInfoAtPosition = source.GetMapInfoAtPosition
      target.getMapLevels = source.GetMapLevels
      target.getMapLinksForMap = source.GetMapLinksForMap
      target.getMapPosFromWorldPos = source.GetMapPosFromWorldPos
      target.getMapRectOnMap = source.GetMapRectOnMap
      target.getMapWorldSize = source.GetMapWorldSize
      target.getPlayerMapPosition = source.GetPlayerMapPosition
      target.getUserWaypoint = source.GetUserWaypoint
      target.getUserWaypointFromHyperlink = source.GetUserWaypointFromHyperlink
      target.getUserWaypointHyperlink = source.GetUserWaypointHyperlink
      target.getUserWaypointPositionForMap = source.GetUserWaypointPositionForMap
      target.getWorldPosFromMapPos = source.GetWorldPosFromMapPos
      target.hasUserWaypoint = source.HasUserWaypoint
      target.isCityMap = source.IsCityMap
      target.isMapValidForNavBarDropdown = source.IsMapValidForNavBarDropdown
      target.mapHasArt = source.MapHasArt
      target.openWorldMap = source.OpenWorldMap
      target.requestPreloadMap = source.RequestPreloadMap
      target.setUserWaypoint = source.SetUserWaypoint
    end
  end
  do
    local source = host.C_MapExplorationInfo
    if source then
      local target = {}
      api.mapExplorationInfo = target
      target.getExploredAreaIDsAtPosition = source.GetExploredAreaIDsAtPosition
      target.getExploredMapTextures = source.GetExploredMapTextures
    end
  end
  do
    local source = host.C_MerchantFrame
    if source then
      local target = {}
      api.merchantFrame = target
      target.getBuybackItemID = source.GetBuybackItemID
      target.getItemInfo = source.GetItemInfo
      target.getMerchantCurrencies = source.GetMerchantCurrencies
      target.getNumJunkItems = source.GetNumJunkItems
      target.isMerchantItemRefundable = source.IsMerchantItemRefundable
      target.isSellAllJunkEnabled = source.IsSellAllJunkEnabled
      target.sellAllJunkItems = source.SellAllJunkItems
    end
  end
  do
    local source = host.C_Minimap
    if source then
      local target = {}
      api.minimap = target
      target.canTrackBattlePets = source.CanTrackBattlePets
      target.clearAllTracking = source.ClearAllTracking
      target.clearMinimapInsetInfo = source.ClearMinimapInsetInfo
      target.getDefaultTrackingValue = source.GetDefaultTrackingValue
      target.getDrawGroundTextures = source.GetDrawGroundTextures
      target.getNumQuestPOIWorldEffects = source.GetNumQuestPOIWorldEffects
      target.getNumTrackingTypes = source.GetNumTrackingTypes
      target.getPOITextureCoords = source.GetPOITextureCoords
      target.getTrackingFilter = source.GetTrackingFilter
      target.getTrackingInfo = source.GetTrackingInfo
      target.getUiMapID = source.GetUiMapID
      target.getViewRadius = source.GetViewRadius
      target.isFilteredOut = source.IsFilteredOut
      target.isInsideQuestBlob = source.IsInsideQuestBlob
      target.isRotateMinimapIgnored = source.IsRotateMinimapIgnored
      target.isTrackingAccountCompletedQuests = source.IsTrackingAccountCompletedQuests
      target.isTrackingBattlePets = source.IsTrackingBattlePets
      target.isTrackingHiddenQuests = source.IsTrackingHiddenQuests
      target.setDrawGroundTextures = source.SetDrawGroundTextures
      target.setIgnoreRotateMinimap = source.SetIgnoreRotateMinimap
      target.setMinimapInsetInfo = source.SetMinimapInsetInfo
      target.setTracking = source.SetTracking
      target.shouldUseHybridMinimap = source.ShouldUseHybridMinimap
    end
  end
  do
    local target = {}
    api.mirrorTimer = target
    target.getMirrorTimerInfo = host.GetMirrorTimerInfo
    target.getMirrorTimerProgress = host.GetMirrorTimerProgress
  end
  do
    local source = host.C_ModelInfo
    if source then
      local target = {}
      api.modelInfo = target
      target.addActiveModelScene = source.AddActiveModelScene
      target.addActiveModelSceneActor = source.AddActiveModelSceneActor
      target.clearActiveModelScene = source.ClearActiveModelScene
      target.clearActiveModelSceneActor = source.ClearActiveModelSceneActor
      target.getModelSceneActorDisplayInfoByID = source.GetModelSceneActorDisplayInfoByID
      target.getModelSceneActorInfoByID = source.GetModelSceneActorInfoByID
      target.getModelSceneCameraInfoByID = source.GetModelSceneCameraInfoByID
      target.getModelSceneInfoByID = source.GetModelSceneInfoByID
    end
  end
  do
    local source = host.C_ModifiedInstance
    if source then
      local target = {}
      api.modifiedInstance = target
      target.getModifiedInstanceInfoFromMapID = source.GetModifiedInstanceInfoFromMapID
    end
  end
  do
    local source = host.C_MountJournal
    if source then
      local target = {}
      api.mountJournal = target
      target.applyMountEquipment = source.ApplyMountEquipment
      target.areMountEquipmentEffectsSuppressed = source.AreMountEquipmentEffectsSuppressed
      target.clearFanfare = source.ClearFanfare
      target.clearRecentFanfares = source.ClearRecentFanfares
      target.dismiss = source.Dismiss
      target.getAllCreatureDisplayIDsForMountID = source.GetAllCreatureDisplayIDsForMountID
      target.getAppliedMountEquipmentID = source.GetAppliedMountEquipmentID
      target.getCollectedDragonridingMounts = source.GetCollectedDragonridingMounts
      target.getCollectedFilterSetting = source.GetCollectedFilterSetting
      target.getDisplayedMountAllCreatureDisplayInfo =
        source.GetDisplayedMountAllCreatureDisplayInfo
      target.getDisplayedMountID = source.GetDisplayedMountID
      target.getDisplayedMountInfo = source.GetDisplayedMountInfo
      target.getDisplayedMountInfoExtra = source.GetDisplayedMountInfoExtra
      target.getDynamicFlightModeSpellID = source.GetDynamicFlightModeSpellID
      target.getIsFavorite = source.GetIsFavorite
      target.getMountAllCreatureDisplayInfoByID = source.GetMountAllCreatureDisplayInfoByID
      target.getMountEquipmentUnlockLevel = source.GetMountEquipmentUnlockLevel
      target.getMountFromItem = source.GetMountFromItem
      target.getMountFromSpell = source.GetMountFromSpell
      target.getMountIDs = source.GetMountIDs
      target.getMountInfoByID = source.GetMountInfoByID
      target.getMountInfoExtraByID = source.GetMountInfoExtraByID
      target.getMountLink = source.GetMountLink
      target.getMountUsabilityByID = source.GetMountUsabilityByID
      target.getNumDisplayedMounts = source.GetNumDisplayedMounts
      target.getNumMounts = source.GetNumMounts
      target.getNumMountsNeedingFanfare = source.GetNumMountsNeedingFanfare
      target.isDragonridingUnlocked = source.IsDragonridingUnlocked
      target.isItemMountEquipment = source.IsItemMountEquipment
      target.isMountEquipmentApplied = source.IsMountEquipmentApplied
      target.isSourceChecked = source.IsSourceChecked
      target.isTypeChecked = source.IsTypeChecked
      target.isUsingDefaultFilters = source.IsUsingDefaultFilters
      target.isValidSourceFilter = source.IsValidSourceFilter
      target.isValidTypeFilter = source.IsValidTypeFilter
      target.needsFanfare = source.NeedsFanfare
      target.pickup = source.Pickup
      target.pickupDynamicFlightMode = source.PickupDynamicFlightMode
      target.setAllSourceFilters = source.SetAllSourceFilters
      target.setAllTypeFilters = source.SetAllTypeFilters
      target.setCollectedFilterSetting = source.SetCollectedFilterSetting
      target.setDefaultFilters = source.SetDefaultFilters
      target.setIsFavorite = source.SetIsFavorite
      target.setSearch = source.SetSearch
      target.setSourceFilter = source.SetSourceFilter
      target.setTypeFilter = source.SetTypeFilter
      target.summonByID = source.SummonByID
      target.swapDynamicFlightMode = source.SwapDynamicFlightMode
    end
  end
  do
    local target = {}
    api.movie = target
    target.cancelPreloadingMovie = host.CancelPreloadingMovie
    target.getMovieDownloadProgress = host.GetMovieDownloadProgress
    target.isMovieLocal = host.IsMovieLocal
    target.isMoviePlayable = host.IsMoviePlayable
    target.isMovieReadable = host.IsMovieReadable
    target.preloadMovie = host.PreloadMovie
  end
  do
    local source = host.C_MythicPlus
    if source then
      local target = {}
      api.mythicPlus = target
      target.getCurrentAffixes = source.GetCurrentAffixes
      target.getCurrentSeason = source.GetCurrentSeason
      target.getCurrentSeasonValues = source.GetCurrentSeasonValues
      target.getCurrentUIDisplaySeason = source.GetCurrentUIDisplaySeason
      target.getEndOfRunGearSequenceLevel = source.GetEndOfRunGearSequenceLevel
      target.getLastWeeklyBestInformation = source.GetLastWeeklyBestInformation
      target.getOwnedKeystoneChallengeMapID = source.GetOwnedKeystoneChallengeMapID
      target.getOwnedKeystoneLevel = source.GetOwnedKeystoneLevel
      target.getOwnedKeystoneMapID = source.GetOwnedKeystoneMapID
      target.getRewardLevelForDifficultyLevel = source.GetRewardLevelForDifficultyLevel
      target.getRewardLevelFromKeystoneLevel = source.GetRewardLevelFromKeystoneLevel
      target.getRunHistory = source.GetRunHistory
      target.getSeasonBestAffixScoreInfoForMap = source.GetSeasonBestAffixScoreInfoForMap
      target.getSeasonBestForMap = source.GetSeasonBestForMap
      target.getSeasonBestMythicRatingFromThisExpansion =
        source.GetSeasonBestMythicRatingFromThisExpansion
      target.getWeeklyBestForMap = source.GetWeeklyBestForMap
      target.getWeeklyChestRewardLevel = source.GetWeeklyChestRewardLevel
      target.isMythicPlusActive = source.IsMythicPlusActive
      target.requestCurrentAffixes = source.RequestCurrentAffixes
      target.requestMapInfo = source.RequestMapInfo
      target.requestRewards = source.RequestRewards
    end
  end
  do
    local source = host.C_NamePlate
    if source then
      local target = {}
      api.namePlate = target
      target.getNamePlateForUnit = source.GetNamePlateForUnit
      target.getNamePlateSize = source.GetNamePlateSize
      target.getNamePlates = source.GetNamePlates
      target.setNamePlateSize = source.SetNamePlateSize
    end
  end
  do
    local source = host.C_NamePlateManager
    if source then
      local target = {}
      api.namePlateManager = target
      target.getNamePlateHitTestInsets = source.GetNamePlateHitTestInsets
      target.isNamePlateUnitBehindCamera = source.IsNamePlateUnitBehindCamera
      target.setNamePlateHitTestInsets = source.SetNamePlateHitTestInsets
      target.setNamePlateSimplified = source.SetNamePlateSimplified
    end
  end
  do
    local source = host.C_Navigation
    if source then
      local target = {}
      api.navigation = target
      target.getDistance = source.GetDistance
      target.getFrame = source.GetFrame
      target.getNearestPartyMemberToken = source.GetNearestPartyMemberToken
      target.getNextWaypointForMap = source.GetNextWaypointForMap
      target.getTargetState = source.GetTargetState
      target.hasValidScreenPosition = source.HasValidScreenPosition
      target.wasClampedToScreen = source.WasClampedToScreen
    end
  end
  do
    local source = host.C_NeighborhoodInitiative
    if source then
      local target = {}
      api.neighborhoodInitiative = target
      target.addTrackedInitiativeTask = source.AddTrackedInitiativeTask
      target.getActiveNeighborhood = source.GetActiveNeighborhood
      target.getAvailableHouseXP = source.GetAvailableHouseXP
      target.getInitiativeActivityLogInfo = source.GetInitiativeActivityLogInfo
      target.getInitiativeTaskChatLink = source.GetInitiativeTaskChatLink
      target.getInitiativeTaskInfo = source.GetInitiativeTaskInfo
      target.getInitiativeTaskRewardScaling = source.GetInitiativeTaskRewardScaling
      target.getNeighborhoodInitiativeInfo = source.GetNeighborhoodInitiativeInfo
      target.getRequiredLevel = source.GetRequiredLevel
      target.getTrackedInitiativeTasks = source.GetTrackedInitiativeTasks
      target.isInitiativeEnabled = source.IsInitiativeEnabled
      target.isPlayerInNeighborhoodGroup = source.IsPlayerInNeighborhoodGroup
      target.isViewingActiveNeighborhood = source.IsViewingActiveNeighborhood
      target.playerHasInitiativeAccess = source.PlayerHasInitiativeAccess
      target.playerMeetsRequiredLevel = source.PlayerMeetsRequiredLevel
      target.removeTrackedInitiativeTask = source.RemoveTrackedInitiativeTask
      target.requestInitiativeActivityLog = source.RequestInitiativeActivityLog
      target.requestNeighborhoodInitiativeInfo = source.RequestNeighborhoodInitiativeInfo
      target.setActiveNeighborhood = source.SetActiveNeighborhood
      target.setViewingNeighborhood = source.SetViewingNeighborhood
    end
  end
  do
    local source = host.C_NewItems
    if source then
      local target = {}
      api.newItems = target
      target.clearAll = source.ClearAll
      target.isNewItem = source.IsNewItem
      target.removeNewItem = source.RemoveNewItem
    end
  end
  do
    local target = {}
    api.os = target
    target.copyToClipboard = host.CopyToClipboard
    target.getTimePreciseSec = host.GetTimePreciseSec
  end
  do
    local source = host.C_PaperDollInfo
    if source then
      local target = {}
      api.paperDollInfo = target
      target.canAutoEquipCursorItem = source.CanAutoEquipCursorItem
      target.canCursorCanGoInSlot = source.CanCursorCanGoInSlot
      target.cancelTemporaryEnchantment = source.CancelTemporaryEnchantment
      target.getArmorEffectiveness = source.GetArmorEffectiveness
      target.getArmorEffectivenessAgainstTarget = source.GetArmorEffectivenessAgainstTarget
      target.getInspectAzeriteItemEmpoweredChoices = source.GetInspectAzeriteItemEmpoweredChoices
      target.getInspectGuildInfo = source.GetInspectGuildInfo
      target.getInspectItemLevel = source.GetInspectItemLevel
      target.getInspectRatedBGBlitzData = source.GetInspectRatedBGBlitzData
      target.getInspectRatedBGData = source.GetInspectRatedBGData
      target.getInspectRatedSoloShuffleData = source.GetInspectRatedSoloShuffleData
      target.getInventorySlotInfo = source.GetInventorySlotInfo
      target.getInventorySlotInfoForInvSlot = source.GetInventorySlotInfoForInvSlot
      target.getMinItemLevel = source.GetMinItemLevel
      target.getStaggerPercentage = source.GetStaggerPercentage
      target.getTemporaryEnchantmentInfo = source.GetTemporaryEnchantmentInfo
      target.isInventorySlotEnabled = source.IsInventorySlotEnabled
      target.isRangedSlotShown = source.IsRangedSlotShown
      target.offhandHasShield = source.OffhandHasShield
      target.offhandHasWeapon = source.OffhandHasWeapon
    end
  end
  do
    local target = {}
    api.parentalControls = target
    target.getSecondsUntilParentalControlsKick = host.GetSecondsUntilParentalControlsKick
  end
  do
    local source = host.C_PartyInfo
    if source then
      local target = {}
      api.partyInfo = target
      target.allowedToDoPartyConversion = source.AllowedToDoPartyConversion
      target.canFormCrossFactionParties = source.CanFormCrossFactionParties
      target.canInvite = source.CanInvite
      target.canStartInstanceAbandonVote = source.CanStartInstanceAbandonVote
      target.challengeModeRestrictionsActive = source.ChallengeModeRestrictionsActive
      target.confirmConvertToRaid = source.ConfirmConvertToRaid
      target.confirmInviteTravelPass = source.ConfirmInviteTravelPass
      target.confirmInviteUnit = source.ConfirmInviteUnit
      target.confirmLeaveParty = source.ConfirmLeaveParty
      target.confirmReadyCheck = source.ConfirmReadyCheck
      target.confirmRequestInviteFromUnit = source.ConfirmRequestInviteFromUnit
      target.convertToParty = source.ConvertToParty
      target.convertToRaid = source.ConvertToRaid
      target.delveTeleportOut = source.DelveTeleportOut
      target.demoteAssistant = source.DemoteAssistant
      target.doCountdown = source.DoCountdown
      target.doReadyCheck = source.DoReadyCheck
      target.getActiveCategories = source.GetActiveCategories
      target.getAvailableLootMethods = source.GetAvailableLootMethods
      target.getInstanceAbandonShutdownTime = source.GetInstanceAbandonShutdownTime
      target.getInstanceAbandonVoteCooldownTime = source.GetInstanceAbandonVoteCooldownTime
      target.getInstanceAbandonVoteRequirements = source.GetInstanceAbandonVoteRequirements
      target.getInstanceAbandonVoteResponse = source.GetInstanceAbandonVoteResponse
      target.getInstanceAbandonVoteTime = source.GetInstanceAbandonVoteTime
      target.getInviteConfirmationInvalidQueues = source.GetInviteConfirmationInvalidQueues
      target.getInviteReferralInfo = source.GetInviteReferralInfo
      target.getLootMethod = source.GetLootMethod
      target.getLootMethodStyle = source.GetLootMethodStyle
      target.getMinItemLevel = source.GetMinItemLevel
      target.getMinLevel = source.GetMinLevel
      target.getNumInstanceAbandonGroupVoteResponses =
        source.GetNumInstanceAbandonGroupVoteResponses
      target.getRestrictPings = source.GetRestrictPings
      target.inviteUnit = source.InviteUnit
      target.isChallengeModeActive = source.IsChallengeModeActive
      target.isChallengeModeKeystoneOwner = source.IsChallengeModeKeystoneOwner
      target.isCrossFactionParty = source.IsCrossFactionParty
      target.isDelveComplete = source.IsDelveComplete
      target.isDelveInProgress = source.IsDelveInProgress
      target.isGUIDInGroup = source.IsGUIDInGroup
      target.isLootMethodAvailable = source.IsLootMethodAvailable
      target.isPartyFull = source.IsPartyFull
      target.isPartyInJailersTower = source.IsPartyInJailersTower
      target.isPartyWalkIn = source.IsPartyWalkIn
      target.leaveParty = source.LeaveParty
      target.promoteToAssistant = source.PromoteToAssistant
      target.promoteToLeader = source.PromoteToLeader
      target.requestInviteFromUnit = source.RequestInviteFromUnit
      target.setEveryoneIsAssistant = source.SetEveryoneIsAssistant
      target.setInstanceAbandonVoteResponse = source.SetInstanceAbandonVoteResponse
      target.setLootMethod = source.SetLootMethod
      target.setRestrictPings = source.SetRestrictPings
      target.startInstanceAbandonVote = source.StartInstanceAbandonVote
      target.uninviteUnit = source.UninviteUnit
    end
  end
  do
    local source = host.C_PartyPose
    if source then
      local target = {}
      api.partyPose = target
      target.extraAction = source.ExtraAction
      target.getPartyPoseInfoByID = source.GetPartyPoseInfoByID
      target.getPartyPoseInfoByMapID = source.GetPartyPoseInfoByMapID
      target.hasExtraAction = source.HasExtraAction
    end
  end
  do
    local target = {}
    api.performanceScript = target
    target.getAddOnCPUUsage = host.GetAddOnCPUUsage
    target.getAddOnMemoryUsage = host.GetAddOnMemoryUsage
    target.getEventCPUUsage = host.GetEventCPUUsage
    target.getFrameCPUUsage = host.GetFrameCPUUsage
    target.getFunctionCPUUsage = host.GetFunctionCPUUsage
    target.getScriptCPUUsage = host.GetScriptCPUUsage
    target.resetCPUUsage = host.ResetCPUUsage
    target.updateAddOnCPUUsage = host.UpdateAddOnCPUUsage
    target.updateAddOnMemoryUsage = host.UpdateAddOnMemoryUsage
  end
  do
    local source = host.C_PerksActivities
    if source then
      local target = {}
      api.perksActivities = target
      target.addTrackedPerksActivity = source.AddTrackedPerksActivity
      target.clearPerksActivitiesPendingCompletion = source.ClearPerksActivitiesPendingCompletion
      target.getAllPerksActivityTags = source.GetAllPerksActivityTags
      target.getPerksActivitiesInfo = source.GetPerksActivitiesInfo
      target.getPerksActivitiesPendingCompletion = source.GetPerksActivitiesPendingCompletion
      target.getPerksActivityChatLink = source.GetPerksActivityChatLink
      target.getPerksActivityInfo = source.GetPerksActivityInfo
      target.getPerksUIThemePrefix = source.GetPerksUIThemePrefix
      target.getTrackedPerksActivities = source.GetTrackedPerksActivities
      target.removeTrackedPerksActivity = source.RemoveTrackedPerksActivity
    end
  end
  do
    local source = host.C_PerksProgram
    if source then
      local target = {}
      api.perksProgram = target
      target.clearFrozenPerksVendorItem = source.ClearFrozenPerksVendorItem
      target.closeInteraction = source.CloseInteraction
      target.getAvailableCategoryIDs = source.GetAvailableCategoryIDs
      target.getAvailableVendorItemIDs = source.GetAvailableVendorItemIDs
      target.getCategoryInfo = source.GetCategoryInfo
      target.getCurrencyAmount = source.GetCurrencyAmount
      target.getDraggedPerksVendorItem = source.GetDraggedPerksVendorItem
      target.getFrozenPerksVendorItemInfo = source.GetFrozenPerksVendorItemInfo
      target.getPendingChestRewards = source.GetPendingChestRewards
      target.getPerksProgramItemDisplayInfo = source.GetPerksProgramItemDisplayInfo
      target.getTimeRemaining = source.GetTimeRemaining
      target.getVendorItemInfo = source.GetVendorItemInfo
      target.getVendorItemInfoRefundTimeLeft = source.GetVendorItemInfoRefundTimeLeft
      target.isAttackAnimToggleEnabled = source.IsAttackAnimToggleEnabled
      target.isFrozenPerksVendorItem = source.IsFrozenPerksVendorItem
      target.isMountSpecialAnimToggleEnabled = source.IsMountSpecialAnimToggleEnabled
      target.itemSelectedTelemetry = source.ItemSelectedTelemetry
      target.pickupPerksVendorItem = source.PickupPerksVendorItem
      target.requestCartCheckout = source.RequestCartCheckout
      target.requestPendingChestRewards = source.RequestPendingChestRewards
      target.requestPurchase = source.RequestPurchase
      target.requestRefund = source.RequestRefund
      target.resetHeldItemDragAndDrop = source.ResetHeldItemDragAndDrop
      target.setFrozenPerksVendorItem = source.SetFrozenPerksVendorItem
    end
  end
  do
    local source = host.C_PetBattles
    if source then
      local target = {}
      api.petBattles = target
      target.getBreedQuality = source.GetBreedQuality
      target.getIcon = source.GetIcon
      target.getName = source.GetName
      target.isPlayerNPC = source.IsPlayerNPC
      target.isWildBattle = source.IsWildBattle
    end
  end
  do
    local source = host.C_PetInfo
    if source then
      local target = {}
      api.petInfo = target
      target.getPetTalentTree = source.GetPetTalentTree
      target.getPetTamersForMap = source.GetPetTamersForMap
      target.getSpellForPetAction = source.GetSpellForPetAction
      target.isPetActionPassive = source.IsPetActionPassive
      target.petAbandon = source.PetAbandon
      target.petAssistMode = source.PetAssistMode
      target.petRename = source.PetRename
    end
  end
  do
    local source = host.C_PetJournal
    if source then
      local target = {}
      api.petJournal = target
      target.clearHoveredBattlePet = source.ClearHoveredBattlePet
      target.clearSearchFilter = source.ClearSearchFilter
      target.dismissSummonedPet = source.DismissSummonedPet
      target.getDisplayIDByIndex = source.GetDisplayIDByIndex
      target.getDisplayProbabilityByIndex = source.GetDisplayProbabilityByIndex
      target.getNonBattlePetLinkByIndex = source.GetNonBattlePetLinkByIndex
      target.getNumDisplays = source.GetNumDisplays
      target.getNumPetsInJournal = source.GetNumPetsInJournal
      target.getOwnedPetIDs = source.GetOwnedPetIDs
      target.getPetAbilityInfo = source.GetPetAbilityInfo
      target.getPetAbilityListTable = source.GetPetAbilityListTable
      target.getPetInfoTableByPetID = source.GetPetInfoTableByPetID
      target.getPetInfoTableBySpeciesID = source.GetPetInfoTableBySpeciesID
      target.getPetLoadOutInfo = source.GetPetLoadOutInfo
      target.getPetSummonInfo = source.GetPetSummonInfo
      target.getSearchFilter = source.GetSearchFilter
      target.hasFavoritePets = source.HasFavoritePets
      target.isCurrentlySummoned = source.IsCurrentlySummoned
      target.isUsingDefaultFilters = source.IsUsingDefaultFilters
      target.petIsSummonable = source.PetIsSummonable
      target.petUsesRandomDisplay = source.PetUsesRandomDisplay
      target.setDefaultFilters = source.SetDefaultFilters
      target.setHoveredBattlePet = source.SetHoveredBattlePet
      target.setSearchFilter = source.SetSearchFilter
      target.spellTargetBattlePet = source.SpellTargetBattlePet
    end
  end
  do
    local source = host.C_PhotoSharing
    if source then
      local target = {}
      api.photoSharing = target
      target.beginAuthorizationFlow = source.BeginAuthorizationFlow
      target.clearAuthorization = source.ClearAuthorization
      target.completeAuthorizationFlow = source.CompleteAuthorizationFlow
      target.getCropRatio = source.GetCropRatio
      target.getPhotoSharingAuthURL = source.GetPhotoSharingAuthURL
      target.getStatus = source.GetStatus
      target.isAuthorized = source.IsAuthorized
      target.isEnabled = source.IsEnabled
      target.setScreenshotPreviewTexture = source.SetScreenshotPreviewTexture
      target.takePhoto = source.TakePhoto
      target.uploadPhotoToService = source.UploadPhotoToService
    end
  end
  do
    local source = host.C_Ping
    if source then
      local target = {}
      api.ping = target
      target.getCooldownInfo = source.GetCooldownInfo
      target.getDefaultPingOptions = source.GetDefaultPingOptions
      target.getTextureKitForType = source.GetTextureKitForType
      target.isPingSystemEnabled = source.IsPingSystemEnabled
      target.sendMacroPing = source.SendMacroPing
      target.togglePingListener = source.TogglePingListener
    end
  end
  do
    local source = host.C_PingSecure
    if source then
      local target = {}
      api.pingSecure = target
      target.clearHitTestPingInfo = source.ClearHitTestPingInfo
      target.createFrame = source.CreateFrame
      target.displayError = source.DisplayError
      target.getTargetPingReceiver = source.GetTargetPingReceiver
      target.sendHitTestPing = source.SendHitTestPing
      target.sendPlayerItemPing = source.SendPlayerItemPing
      target.sendPlayerSpellCategoryPing = source.SendPlayerSpellCategoryPing
      target.sendPlayerSpellPing = source.SendPlayerSpellPing
      target.sendUnitPing = source.SendUnitPing
      target.setHitTestPingTarget = source.SetHitTestPingTarget
      target.setHitTestTargetAndSendPing = source.SetHitTestTargetAndSendPing
      target.setPendingPingOffScreenCallback = source.SetPendingPingOffScreenCallback
      target.setPingCooldownStartedCallback = source.SetPingCooldownStartedCallback
      target.setPingPinFrameAddedCallback = source.SetPingPinFrameAddedCallback
      target.setPingPinFrameRemovedCallback = source.SetPingPinFrameRemovedCallback
      target.setPingPinFrameScreenClampStateUpdatedCallback =
        source.SetPingPinFrameScreenClampStateUpdatedCallback
      target.setPingRadialWheelCreatedCallback = source.SetPingRadialWheelCreatedCallback
      target.setSendMacroPingCallback = source.SetSendMacroPingCallback
      target.setTogglePingListenerCallback = source.SetTogglePingListenerCallback
    end
  end
  do
    local source = host.C_Platform
    if source then
      local target = {}
      api.platform = target
    end
  end
  do
    local source = host.C_PlayerChoice
    if source then
      local target = {}
      api.playerChoice = target
      target.getCurrentPlayerChoiceInfo = source.GetCurrentPlayerChoiceInfo
      target.getNumRerolls = source.GetNumRerolls
      target.getRemainingTime = source.GetRemainingTime
      target.isWaitingForPlayerChoiceResponse = source.IsWaitingForPlayerChoiceResponse
      target.onUIClosed = source.OnUIClosed
      target.requestRerollPlayerChoice = source.RequestRerollPlayerChoice
      target.sendPlayerChoiceResponse = source.SendPlayerChoiceResponse
    end
  end
  do
    local source = host.C_PlayerInfo
    if source then
      local target = {}
      api.playerInfo = target
      target.canPlayerEnterChromieTime = source.CanPlayerEnterChromieTime
      target.canPlayerUseAreaLoot = source.CanPlayerUseAreaLoot
      target.canPlayerUseMountEquipment = source.CanPlayerUseMountEquipment
      target.canUseItem = source.CanUseItem
      target.guidIsPlayer = source.GUIDIsPlayer
      target.getAlternateFormInfo = source.GetAlternateFormInfo
      target.getClass = source.GetClass
      target.getContentDifficultyCreatureForPlayer = source.GetContentDifficultyCreatureForPlayer
      target.getContentDifficultyQuestForPlayer = source.GetContentDifficultyQuestForPlayer
      target.getDisplayID = source.GetDisplayID
      target.getGlidingInfo = source.GetGlidingInfo
      target.getInstancesUnlockedAtLevel = source.GetInstancesUnlockedAtLevel
      target.getName = source.GetName
      target.getNativeDisplayID = source.GetNativeDisplayID
      target.getPetStableCreatureDisplayInfoID = source.GetPetStableCreatureDisplayInfoID
      target.getPlayerCharacterData = source.GetPlayerCharacterData
      target.getPlayerMythicPlusRatingSummary = source.GetPlayerMythicPlusRatingSummary
      target.getRace = source.GetRace
      target.getSex = source.GetSex
      target.hasAccountInventoryLock = source.HasAccountInventoryLock
      target.hasVisibleInvSlot = source.HasVisibleInvSlot
      target.isAccountBankEnabled = source.IsAccountBankEnabled
      target.isCharacterBankEnabled = source.IsCharacterBankEnabled
      target.isConnected = source.IsConnected
      target.isDisplayRaceNative = source.IsDisplayRaceNative
      target.isExpansionLandingPageUnlockedForPlayer =
        source.IsExpansionLandingPageUnlockedForPlayer
      target.isMirrorImage = source.IsMirrorImage
      target.isPlayerEligibleForNPE = source.IsPlayerEligibleForNPE
      target.isPlayerEligibleForNPEv2 = source.IsPlayerEligibleForNPEv2
      target.isPlayerInChromieTime = source.IsPlayerInChromieTime
      target.isPlayerInRPE = source.IsPlayerInRPE
      target.isPlayerInTimerunningHeroicWorldTier = source.IsPlayerInTimerunningHeroicWorldTier
      target.isPlayerNPERestricted = source.IsPlayerNPERestricted
      target.isReturningCharacter = source.IsReturningCharacter
      target.isSelfFoundActive = source.IsSelfFoundActive
      target.isTradingPostAvailable = source.IsTradingPostAvailable
      target.isTravelersLogAvailable = source.IsTravelersLogAvailable
      target.isTutorialsTabAvailable = source.IsTutorialsTabAvailable
      target.unitIsSameServer = source.UnitIsSameServer
    end
  end
  do
    local source = host.C_PlayerInteractionManager
    if source then
      local target = {}
      api.playerInteractionManager = target
      target.clearInteraction = source.ClearInteraction
      target.confirmationInteraction = source.ConfirmationInteraction
      target.interactUnit = source.InteractUnit
      target.isInteractingWithNpcOfType = source.IsInteractingWithNpcOfType
      target.isReplacingUnit = source.IsReplacingUnit
      target.isValidNPCInteraction = source.IsValidNPCInteraction
      target.reopenInteraction = source.ReopenInteraction
    end
  end
  do
    local source = host.C_PlayerMentorship
    if source then
      local target = {}
      api.playerMentorship = target
      target.getMentorLevelRequirement = source.GetMentorLevelRequirement
      target.getMentorRequirements = source.GetMentorRequirements
      target.getMentorshipStatus = source.GetMentorshipStatus
      target.isActivePlayerConsideredNewcomer = source.IsActivePlayerConsideredNewcomer
      target.isMentorRestricted = source.IsMentorRestricted
    end
  end
  do
    local target = {}
    api.playerScript = target
    target.acceptAreaSpiritHeal = host.AcceptAreaSpiritHeal
    target.acceptGuild = host.AcceptGuild
    target.acceptResurrect = host.AcceptResurrect
    target.ambiguate = host.Ambiguate
    target.autoEquipCursorItem = host.AutoEquipCursorItem
    target.beginTrade = host.BeginTrade
    target.canDualWield = host.CanDualWield
    target.canInspect = host.CanInspect
    target.canLootUnit = host.CanLootUnit
    target.cancelAreaSpiritHeal = host.CancelAreaSpiritHeal
    target.cancelPendingEquip = host.CancelPendingEquip
    target.cancelTrade = host.CancelTrade
    target.checkInteractDistance = host.CheckInteractDistance
    target.checkTalentMasterDist = host.CheckTalentMasterDist
    target.clearPendingBindConversionItem = host.ClearPendingBindConversionItem
    target.confirmTalentWipe = host.ConfirmTalentWipe
    target.convertItemToBindToAccount = host.ConvertItemToBindToAccount
    target.declineGuild = host.DeclineGuild
    target.declineResurrect = host.DeclineResurrect
    target.dismount = host.Dismount
    target.equipPendingItem = host.EquipPendingItem
    target.followUnit = host.FollowUnit
    target.getAllowLowLevelRaid = host.GetAllowLowLevelRaid
    target.getAllowRecentAlliesSeeLocation = host.GetAllowRecentAlliesSeeLocation
    target.getAreaSpiritHealerTime = host.GetAreaSpiritHealerTime
    target.getAttackPowerForStat = host.GetAttackPowerForStat
    target.getAutoDeclineGuildInvites = host.GetAutoDeclineGuildInvites
    target.getAutoDeclineNeighborhoodInvites = host.GetAutoDeclineNeighborhoodInvites
    target.getAvoidance = host.GetAvoidance
    target.getBindLocation = host.GetBindLocation
    target.getBlockChance = host.GetBlockChance
    target.getCemeteryPreference = host.GetCemeteryPreference
    target.getCollapsingStarCost = host.GetCollapsingStarCost
    target.getCombatRating = host.GetCombatRating
    target.getCombatRatingBonus = host.GetCombatRatingBonus
    target.getCombatRatingBonusForCombatRatingValue = host.GetCombatRatingBonusForCombatRatingValue
    target.getCorpseRecoveryDelay = host.GetCorpseRecoveryDelay
    target.getCorruption = host.GetCorruption
    target.getCorruptionResistance = host.GetCorruptionResistance
    target.getCritChance = host.GetCritChance
    target.getCritChanceProvidesParryEffect = host.GetCritChanceProvidesParryEffect
    target.getDodgeChance = host.GetDodgeChance
    target.getDodgeChanceFromAttribute = host.GetDodgeChanceFromAttribute
    target.getExpertise = host.GetExpertise
    target.getExpertisePercent = host.GetExpertisePercent
    target.getHaste = host.GetHaste
    target.getHitModifier = host.GetHitModifier
    target.getJailersTowerLevel = host.GetJailersTowerLevel
    target.getLifesteal = host.GetLifesteal
    target.getLootSpecialization = host.GetLootSpecialization
    target.getManaRegen = host.GetManaRegen
    target.getMastery = host.GetMastery
    target.getMasteryEffect = host.GetMasteryEffect
    target.getMaxPlayerLevel = host.GetMaxPlayerLevel
    target.getMeleeHaste = host.GetMeleeHaste
    target.getModResilienceDamageReduction = host.GetModResilienceDamageReduction
    target.getMoney = host.GetMoney
    target.getNormalizedRealmName = host.GetNormalizedRealmName
    target.getOverrideAPBySpellPower = host.GetOverrideAPBySpellPower
    target.getOverrideSpellPowerByAP = host.GetOverrideSpellPowerByAP
    target.getPVPDesired = host.GetPVPDesired
    target.getPVPGearStatRules = host.GetPVPGearStatRules
    target.getPVPLifetimeStats = host.GetPVPLifetimeStats
    target.getPVPSessionStats = host.GetPVPSessionStats
    target.getPVPTimer = host.GetPVPTimer
    target.getPVPYesterdayStats = host.GetPVPYesterdayStats
    target.getParryChance = host.GetParryChance
    target.getParryChanceFromAttribute = host.GetParryChanceFromAttribute
    target.getPetMeleeHaste = host.GetPetMeleeHaste
    target.getPetSpellBonusDamage = host.GetPetSpellBonusDamage
    target.getPlayerFacing = host.GetPlayerFacing
    target.getPlayerInfoByGUID = host.GetPlayerInfoByGUID
    target.getPowerRegen = host.GetPowerRegen
    target.getPowerRegenForPowerType = host.GetPowerRegenForPowerType
    target.getPvpPowerDamage = host.GetPvpPowerDamage
    target.getPvpPowerHealing = host.GetPvpPowerHealing
    target.getRangedCritChance = host.GetRangedCritChance
    target.getRangedHaste = host.GetRangedHaste
    target.getReleaseTimeRemaining = host.GetReleaseTimeRemaining
    target.getResSicknessDuration = host.GetResSicknessDuration
    target.getRestState = host.GetRestState
    target.getRestrictedAccountData = host.GetRestrictedAccountData
    target.getRuneCooldown = host.GetRuneCooldown
    target.getRuneCount = host.GetRuneCount
    target.getSheathState = host.GetSheathState
    target.getShieldBlock = host.GetShieldBlock
    target.getSpeed = host.GetSpeed
    target.getSpellBonusDamage = host.GetSpellBonusDamage
    target.getSpellBonusHealing = host.GetSpellBonusHealing
    target.getSpellCritChance = host.GetSpellCritChance
    target.getSpellHitModifier = host.GetSpellHitModifier
    target.getSpellPenetration = host.GetSpellPenetration
    target.getSturdiness = host.GetSturdiness
    target.getTaxiBenchmarkMode = host.GetTaxiBenchmarkMode
    target.getVersatilityBonus = host.GetVersatilityBonus
    target.getXPExhaustion = host.GetXPExhaustion
    target.hasAPEffectsSpellPower = host.HasAPEffectsSpellPower
    target.hasDualWieldPenalty = host.HasDualWieldPenalty
    target.hasFullControl = host.HasFullControl
    target.hasIgnoreDualWieldWeapon = host.HasIgnoreDualWieldWeapon
    target.hasKey = host.HasKey
    target.hasNoReleaseAura = host.HasNoReleaseAura
    target.hasSPEffectsAttackPower = host.HasSPEffectsAttackPower
    target.initiateTrade = host.InitiateTrade
    target.isAccountSecured = host.IsAccountSecured
    target.isAdvancedFlyableArea = host.IsAdvancedFlyableArea
    target.isCemeterySelectionAvailable = host.IsCemeterySelectionAvailable
    target.isCharacterNewlyBoosted = host.IsCharacterNewlyBoosted
    target.isDrivableArea = host.IsDrivableArea
    target.isDualWielding = host.IsDualWielding
    target.isFlyableArea = host.IsFlyableArea
    target.isGuildLeader = host.IsGuildLeader
    target.isInGuild = host.IsInGuild
    target.isInJailersTower = host.IsInJailersTower
    target.isIndoors = host.IsIndoors
    target.isInsane = host.IsInsane
    target.isItemPreferredArmorType = host.IsItemPreferredArmorType
    target.isJailersTowerLayerTimeLocked = host.IsJailersTowerLayerTimeLocked
    target.isLoggedIn = host.IsLoggedIn
    target.isMounted = host.IsMounted
    target.isOnGroundFloorInJailersTower = host.IsOnGroundFloorInJailersTower
    target.isOutOfBounds = host.IsOutOfBounds
    target.isOutdoors = host.IsOutdoors
    target.isPVPTimerRunning = host.IsPVPTimerRunning
    target.isPlayerInWorld = host.IsPlayerInWorld
    target.isPlayerMoving = host.IsPlayerMoving
    target.isRangedWeapon = host.IsRangedWeapon
    target.isResting = host.IsResting
    target.isRestrictedAccount = host.IsRestrictedAccount
    target.isStealthed = host.IsStealthed
    target.isXPUserDisabled = host.IsXPUserDisabled
    target.noPlayTime = host.NoPlayTime
    target.notifyInspect = host.NotifyInspect
    target.partialPlayTime = host.PartialPlayTime
    target.playerCanTeleport = host.PlayerCanTeleport
    target.playerEffectiveAttackPower = host.PlayerEffectiveAttackPower
    target.playerGetTimerunningSeasonID = host.PlayerGetTimerunningSeasonID
    target.playerIsInCombat = host.PlayerIsInCombat
    target.playerIsTimerunning = host.PlayerIsTimerunning
    target.portGraveyard = host.PortGraveyard
    target.randomRoll = host.RandomRoll
    target.repopMe = host.RepopMe
    target.requestTimePlayed = host.RequestTimePlayed
    target.respondInstanceLock = host.RespondInstanceLock
    target.resurrectGetOfferer = host.ResurrectGetOfferer
    target.resurrectHasSickness = host.ResurrectHasSickness
    target.resurrectHasTimer = host.ResurrectHasTimer
    target.retrieveCorpse = host.RetrieveCorpse
    target.setAllowLowLevelRaid = host.SetAllowLowLevelRaid
    target.setAllowRecentAlliesSeeLocation = host.SetAllowRecentAlliesSeeLocation
    target.setAutoDeclineGuildInvites = host.SetAutoDeclineGuildInvites
    target.setAutoDeclineNeighborhoodInvites = host.SetAutoDeclineNeighborhoodInvites
    target.setCemeteryPreference = host.SetCemeteryPreference
    target.setLootSpecialization = host.SetLootSpecialization
    target.setTaxiBenchmarkMode = host.SetTaxiBenchmarkMode
    target.shouldShowIslandsWeeklyPOI = host.ShouldShowIslandsWeeklyPOI
    target.shouldShowSpecialSplashScreen = host.ShouldShowSpecialSplashScreen
    target.showCloak = host.ShowCloak
    target.showHelm = host.ShowHelm
    target.showingCloak = host.ShowingCloak
    target.showingHelm = host.ShowingHelm
    target.sitStandOrDescendStart = host.SitStandOrDescendStart
    target.splashFrameCanBeShown = host.SplashFrameCanBeShown
    target.startAttack = host.StartAttack
    target.stopAttack = host.StopAttack
    target.stuck = host.Stuck
    target.timeoutResurrect = host.TimeoutResurrect
    target.toggleSelfHighlight = host.ToggleSelfHighlight
    target.toggleSheath = host.ToggleSheath
  end
  do
    local source = host.C_Pony
    if source then
      local target = {}
      api.pony = target
    end
  end
  do
    local source = host.C_ProfSpecs
    if source then
      local target = {}
      api.profSpecs = target
      target.canRefundPath = source.CanRefundPath
      target.canUnlockTab = source.CanUnlockTab
      target.getChildrenForPath = source.GetChildrenForPath
      target.getConfigIDForSkillLine = source.GetConfigIDForSkillLine
      target.getCurrencyInfoForSkillLine = source.GetCurrencyInfoForSkillLine
      target.getDefaultSpecSkillLine = source.GetDefaultSpecSkillLine
      target.getDescriptionForPath = source.GetDescriptionForPath
      target.getDescriptionForPerk = source.GetDescriptionForPerk
      target.getEntryIDForPerk = source.GetEntryIDForPerk
      target.getNewSpecReminderProfName = source.GetNewSpecReminderProfName
      target.getPerksForPath = source.GetPerksForPath
      target.getRootPathForTab = source.GetRootPathForTab
      target.getSourceTextForPath = source.GetSourceTextForPath
      target.getSpecTabIDsForSkillLine = source.GetSpecTabIDsForSkillLine
      target.getSpecTabInfo = source.GetSpecTabInfo
      target.getSpendCurrencyForPath = source.GetSpendCurrencyForPath
      target.getSpendEntryForPath = source.GetSpendEntryForPath
      target.getStateForPath = source.GetStateForPath
      target.getStateForPerk = source.GetStateForPerk
      target.getStateForTab = source.GetStateForTab
      target.getTabInfo = source.GetTabInfo
      target.getUnlockEntryForPath = source.GetUnlockEntryForPath
      target.getUnlockRankForPerk = source.GetUnlockRankForPerk
      target.shouldShowPointsReminder = source.ShouldShowPointsReminder
      target.shouldShowPointsReminderForSkillLine = source.ShouldShowPointsReminderForSkillLine
      target.shouldShowSpecTab = source.ShouldShowSpecTab
      target.skillLineHasSpecialization = source.SkillLineHasSpecialization
    end
  end
  do
    local source = host.C_PvP
    if source then
      local target = {}
      api.pvp = target
      target.arePvpTalentsUnlocked = source.ArePvpTalentsUnlocked
      target.areTrainingGroundsEnabled = source.AreTrainingGroundsEnabled
      target.canDisplayDeaths = source.CanDisplayDeaths
      target.canDisplayHonorableKills = source.CanDisplayHonorableKills
      target.canPlayerUseRatedPVPUI = source.CanPlayerUseRatedPVPUI
      target.canPlayerUseTrainingGroundsUI = source.CanPlayerUseTrainingGroundsUI
      target.canSurrenderArena = source.CanSurrenderArena
      target.canToggleWarMode = source.CanToggleWarMode
      target.canToggleWarModeInArea = source.CanToggleWarModeInArea
      target.doesMatchOutcomeAffectRating = source.DoesMatchOutcomeAffectRating
      target.getActiveBrawlInfo = source.GetActiveBrawlInfo
      target.getActiveMatchBracket = source.GetActiveMatchBracket
      target.getActiveMatchDuration = source.GetActiveMatchDuration
      target.getActiveMatchState = source.GetActiveMatchState
      target.getActiveMatchWinner = source.GetActiveMatchWinner
      target.getArenaCrowdControlDuration = source.GetArenaCrowdControlDuration
      target.getArenaCrowdControlInfo = source.GetArenaCrowdControlInfo
      target.getArenaRewards = source.GetArenaRewards
      target.getArenaSkirmishRewards = source.GetArenaSkirmishRewards
      target.getAssignedSpecForBattlefieldQueue = source.GetAssignedSpecForBattlefieldQueue
      target.getAvailableBrawlInfo = source.GetAvailableBrawlInfo
      target.getBattlefieldFlagPosition = source.GetBattlefieldFlagPosition
      target.getBattlefieldVehicleInfo = source.GetBattlefieldVehicleInfo
      target.getBattlefieldVehicles = source.GetBattlefieldVehicles
      target.getBattlegroundInfo = source.GetBattlegroundInfo
      target.getBrawlRewards = source.GetBrawlRewards
      target.getBrawlSoloRBGMinItemLevel = source.GetBrawlSoloRBGMinItemLevel
      target.getCustomVictoryStatID = source.GetCustomVictoryStatID
      target.getGlobalPvpScalingInfoForSpecID = source.GetGlobalPvpScalingInfoForSpecID
      target.getHonorRewardInfo = source.GetHonorRewardInfo
      target.getLevelUpBattlegrounds = source.GetLevelUpBattlegrounds
      target.getMatchPVPStatColumn = source.GetMatchPVPStatColumn
      target.getMatchPVPStatColumns = source.GetMatchPVPStatColumns
      target.getNextHonorLevelForReward = source.GetNextHonorLevelForReward
      target.getOutdoorPvPWaitTime = source.GetOutdoorPvPWaitTime
      target.getPVPActiveMatchPersonalRatedInfo = source.GetPVPActiveMatchPersonalRatedInfo
      target.getPVPActiveRatedMatchDeserterPenalty = source.GetPVPActiveRatedMatchDeserterPenalty
      target.getPVPSeasonRewardAchievementID = source.GetPVPSeasonRewardAchievementID
      target.getPersonalRatedBGBlitzSpecStats = source.GetPersonalRatedBGBlitzSpecStats
      target.getPersonalRatedSoloShuffleSpecStats = source.GetPersonalRatedSoloShuffleSpecStats
      target.getPostMatchCurrencyRewards = source.GetPostMatchCurrencyRewards
      target.getPostMatchItemRewards = source.GetPostMatchItemRewards
      target.getPvpTalentsUnlockedLevel = source.GetPvpTalentsUnlockedLevel
      target.getPvpTierID = source.GetPvpTierID
      target.getPvpTierInfo = source.GetPvpTierInfo
      target.getRandomBGInfo = source.GetRandomBGInfo
      target.getRandomBGRewards = source.GetRandomBGRewards
      target.getRandomEpicBGInfo = source.GetRandomEpicBGInfo
      target.getRandomEpicBGRewards = source.GetRandomEpicBGRewards
      target.getRandomTrainingGroundRewards = source.GetRandomTrainingGroundRewards
      target.getRatedBGRewards = source.GetRatedBGRewards
      target.getRatedSoloRBGMinItemLevel = source.GetRatedSoloRBGMinItemLevel
      target.getRatedSoloRBGRewards = source.GetRatedSoloRBGRewards
      target.getRatedSoloShuffleMinItemLevel = source.GetRatedSoloShuffleMinItemLevel
      target.getRatedSoloShuffleRewards = source.GetRatedSoloShuffleRewards
      target.getRewardItemLevelsByTierEnum = source.GetRewardItemLevelsByTierEnum
      target.getScoreInfo = source.GetScoreInfo
      target.getScoreInfoByPlayerGuid = source.GetScoreInfoByPlayerGuid
      target.getSeasonBestInfo = source.GetSeasonBestInfo
      target.getSkirmishInfo = source.GetSkirmishInfo
      target.getSpecialEventBrawlInfo = source.GetSpecialEventBrawlInfo
      target.getTeamInfo = source.GetTeamInfo
      target.getTrainingGrounds = source.GetTrainingGrounds
      target.getUIDisplaySeason = source.GetUIDisplaySeason
      target.getWarModeRewardBonus = source.GetWarModeRewardBonus
      target.getWarModeRewardBonusDefault = source.GetWarModeRewardBonusDefault
      target.getWeeklyChestInfo = source.GetWeeklyChestInfo
      target.getZonePVPInfo = source.GetZonePVPInfo
      target.hasArenaSkirmishWinToday = source.HasArenaSkirmishWinToday
      target.hasMatchStarted = source.HasMatchStarted
      target.hasRandomTrainingGroundWinToday = source.HasRandomTrainingGroundWinToday
      target.isActiveBattlefield = source.IsActiveBattlefield
      target.isActiveMatchRegistered = source.IsActiveMatchRegistered
      target.isArena = source.IsArena
      target.isBattleground = source.IsBattleground
      target.isBattlegroundEnlistmentBonusActive = source.IsBattlegroundEnlistmentBonusActive
      target.isBrawlSoloRBG = source.IsBrawlSoloRBG
      target.isBrawlSoloShuffle = source.IsBrawlSoloShuffle
      target.isInBrawl = source.IsInBrawl
      target.isInRatedMatchWithDeserterPenalty = source.IsInRatedMatchWithDeserterPenalty
      target.isMatchActive = source.IsMatchActive
      target.isMatchComplete = source.IsMatchComplete
      target.isMatchConsideredArena = source.IsMatchConsideredArena
      target.isMatchFactional = source.IsMatchFactional
      target.isPVPMap = source.IsPVPMap
      target.isRatedArena = source.IsRatedArena
      target.isRatedBattleground = source.IsRatedBattleground
      target.isRatedMap = source.IsRatedMap
      target.isRatedSoloRBG = source.IsRatedSoloRBG
      target.isRatedSoloShuffle = source.IsRatedSoloShuffle
      target.isSoloRBG = source.IsSoloRBG
      target.isSoloShuffle = source.IsSoloShuffle
      target.isSubZonePVPPOI = source.IsSubZonePVPPOI
      target.isWarModeActive = source.IsWarModeActive
      target.isWarModeDesired = source.IsWarModeDesired
      target.isWarModeFeatureEnabled = source.IsWarModeFeatureEnabled
      target.joinBattlefield = source.JoinBattlefield
      target.joinBrawl = source.JoinBrawl
      target.joinRandomTrainingGroundArena = source.JoinRandomTrainingGroundArena
      target.joinRandomTrainingGroundBattleground = source.JoinRandomTrainingGroundBattleground
      target.joinRatedBGBlitz = source.JoinRatedBGBlitz
      target.joinTrainingGround = source.JoinTrainingGround
      target.requestCrowdControlSpell = source.RequestCrowdControlSpell
      target.setPVP = source.SetPVP
      target.setWarModeDesired = source.SetWarModeDesired
      target.startSoloRBGWarGameByName = source.StartSoloRBGWarGameByName
      target.startSpectatorSoloRBGWarGame = source.StartSpectatorSoloRBGWarGame
      target.togglePVP = source.TogglePVP
      target.toggleWarMode = source.ToggleWarMode
    end
  end
  do
    local source = host.C_QuestHub
    if source then
      local target = {}
      api.questHub = target
      target.isAreaPOICurrentlyRelatedToHub = source.IsAreaPOICurrentlyRelatedToHub
      target.isQuestCurrentlyRelatedToHub = source.IsQuestCurrentlyRelatedToHub
    end
  end
  do
    local source = host.C_QuestInfoSystem
    if source then
      local target = {}
      api.questInfoSystem = target
      target.getQuestClassification = source.GetQuestClassification
      target.getQuestHasShortExpirationWarning = source.GetQuestHasShortExpirationWarning
      target.getQuestLogRewardFavor = source.GetQuestLogRewardFavor
      target.getQuestRewardCurrencies = source.GetQuestRewardCurrencies
      target.getQuestRewardSpellInfo = source.GetQuestRewardSpellInfo
      target.getQuestRewardSpells = source.GetQuestRewardSpells
      target.getQuestShouldToastCompletion = source.GetQuestShouldToastCompletion
      target.hasQuestRewardCurrencies = source.HasQuestRewardCurrencies
      target.hasQuestRewardSpells = source.HasQuestRewardSpells
    end
  end
  do
    local source = host.C_QuestItemUse
    if source then
      local target = {}
      api.questItemUse = target
      target.canUseQuestItemOnObject = source.CanUseQuestItemOnObject
    end
  end
  do
    local source = host.C_QuestLine
    if source then
      local target = {}
      api.questLine = target
      target.getAvailableQuestLines = source.GetAvailableQuestLines
      target.getForceVisibleQuests = source.GetForceVisibleQuests
      target.getQuestLineInfo = source.GetQuestLineInfo
      target.getQuestLineQuests = source.GetQuestLineQuests
      target.isComplete = source.IsComplete
      target.questLineIgnoresAccountCompletedFiltering =
        source.QuestLineIgnoresAccountCompletedFiltering
      target.requestQuestLinesForMap = source.RequestQuestLinesForMap
    end
  end
  do
    local source = host.C_QuestLog
    if source then
      local target = {}
      api.questLog = target
      target.abandonQuest = source.AbandonQuest
      target.addQuestWatch = source.AddQuestWatch
      target.addWorldQuestWatch = source.AddWorldQuestWatch
      target.canAbandonQuest = source.CanAbandonQuest
      target.doesQuestAwardReputationWithFaction = source.DoesQuestAwardReputationWithFaction
      target.getAbandonQuest = source.GetAbandonQuest
      target.getAbandonQuestItems = source.GetAbandonQuestItems
      target.getActivePreyQuest = source.GetActivePreyQuest
      target.getActiveThreatMaps = source.GetActiveThreatMaps
      target.getAllCompletedQuestIDs = source.GetAllCompletedQuestIDs
      target.getBountiesForMapID = source.GetBountiesForMapID
      target.getBountySetInfoForMapID = source.GetBountySetInfoForMapID
      target.getDistanceSqToQuest = source.GetDistanceSqToQuest
      target.getHeaderIndexForQuest = source.GetHeaderIndexForQuest
      target.getInfo = source.GetInfo
      target.getLogIndexForQuestID = source.GetLogIndexForQuestID
      target.getMapForQuestPOIs = source.GetMapForQuestPOIs
      target.getMaxNumQuests = source.GetMaxNumQuests
      target.getMaxNumQuestsCanAccept = source.GetMaxNumQuestsCanAccept
      target.getNextWaypoint = source.GetNextWaypoint
      target.getNextWaypointForMap = source.GetNextWaypointForMap
      target.getNextWaypointText = source.GetNextWaypointText
      target.getNumQuestLogEntries = source.GetNumQuestLogEntries
      target.getNumQuestObjectives = source.GetNumQuestObjectives
      target.getNumQuestWatches = source.GetNumQuestWatches
      target.getNumWorldQuestWatches = source.GetNumWorldQuestWatches
      target.getQuestAdditionalHighlights = source.GetQuestAdditionalHighlights
      target.getQuestDetailsTheme = source.GetQuestDetailsTheme
      target.getQuestDifficultyLevel = source.GetQuestDifficultyLevel
      target.getQuestIDForLogIndex = source.GetQuestIDForLogIndex
      target.getQuestIDForQuestWatchIndex = source.GetQuestIDForQuestWatchIndex
      target.getQuestIDForWorldQuestWatchIndex = source.GetQuestIDForWorldQuestWatchIndex
      target.getQuestLogMajorFactionReputationRewards =
        source.GetQuestLogMajorFactionReputationRewards
      target.getQuestLogPortraitGiver = source.GetQuestLogPortraitGiver
      target.getQuestObjectives = source.GetQuestObjectives
      target.getQuestRewardCurrencies = source.GetQuestRewardCurrencies
      target.getQuestRewardCurrencyInfo = source.GetQuestRewardCurrencyInfo
      target.getQuestTagInfo = source.GetQuestTagInfo
      target.getQuestType = source.GetQuestType
      target.getQuestWatchType = source.GetQuestWatchType
      target.getQuestsOnMap = source.GetQuestsOnMap
      target.getRequiredMoney = source.GetRequiredMoney
      target.getSelectedQuest = source.GetSelectedQuest
      target.getSuggestedGroupSize = source.GetSuggestedGroupSize
      target.getTimeAllowed = source.GetTimeAllowed
      target.getTitleForLogIndex = source.GetTitleForLogIndex
      target.getTitleForQuestID = source.GetTitleForQuestID
      target.getZoneStoryInfo = source.GetZoneStoryInfo
      target.hasActiveThreats = source.HasActiveThreats
      target.isAccountQuest = source.IsAccountQuest
      target.isComplete = source.IsComplete
      target.isFailed = source.IsFailed
      target.isImportantQuest = source.IsImportantQuest
      target.isMetaQuest = source.IsMetaQuest
      target.isOnMap = source.IsOnMap
      target.isOnQuest = source.IsOnQuest
      target.isPushableQuest = source.IsPushableQuest
      target.isQuestBounty = source.IsQuestBounty
      target.isQuestCalling = source.IsQuestCalling
      target.isQuestCriteriaForBounty = source.IsQuestCriteriaForBounty
      target.isQuestDisabledForSession = source.IsQuestDisabledForSession
      target.isQuestFlaggedCompleted = source.IsQuestFlaggedCompleted
      target.isQuestFlaggedCompletedOnAccount = source.IsQuestFlaggedCompletedOnAccount
      target.isQuestFromContentPush = source.IsQuestFromContentPush
      target.isQuestInvasion = source.IsQuestInvasion
      target.isQuestReplayable = source.IsQuestReplayable
      target.isQuestReplayedRecently = source.IsQuestReplayedRecently
      target.isQuestTask = source.IsQuestTask
      target.isQuestTrivial = source.IsQuestTrivial
      target.isRepeatableQuest = source.IsRepeatableQuest
      target.isThreatQuest = source.IsThreatQuest
      target.isUnitOnQuest = source.IsUnitOnQuest
      target.isWorldQuest = source.IsWorldQuest
      target.questCanHaveWarModeBonus = source.QuestCanHaveWarModeBonus
      target.questContainsFirstTimeRepBonusForPlayer =
        source.QuestContainsFirstTimeRepBonusForPlayer
      target.questHasQuestSessionBonus = source.QuestHasQuestSessionBonus
      target.questHasWarModeBonus = source.QuestHasWarModeBonus
      target.questIgnoresAccountCompletedFiltering = source.QuestIgnoresAccountCompletedFiltering
      target.readyForTurnIn = source.ReadyForTurnIn
      target.removeQuestWatch = source.RemoveQuestWatch
      target.removeWorldQuestWatch = source.RemoveWorldQuestWatch
      target.requestLoadQuestByID = source.RequestLoadQuestByID
      target.setAbandonQuest = source.SetAbandonQuest
      target.setMapForQuestPOIs = source.SetMapForQuestPOIs
      target.setSelectedQuest = source.SetSelectedQuest
      target.shouldDisplayTimeRemaining = source.ShouldDisplayTimeRemaining
      target.shouldShowQuestRewards = source.ShouldShowQuestRewards
      target.sortQuestWatches = source.SortQuestWatches
      target.unitIsRelatedToActiveQuest = source.UnitIsRelatedToActiveQuest
      target.updateCampaignHeaders = source.UpdateCampaignHeaders
    end
  end
  do
    local source = host.C_QuestOffer
    if source then
      local target = {}
      api.questOffer = target
      target.getHideRequiredItems = source.GetHideRequiredItems
      target.getQuestOfferMajorFactionReputationRewards =
        source.GetQuestOfferMajorFactionReputationRewards
      target.getQuestRequiredCurrencyInfo = source.GetQuestRequiredCurrencyInfo
      target.getQuestRewardCurrencyInfo = source.GetQuestRewardCurrencyInfo
    end
  end
  do
    local source = host.C_QuestSession
    if source then
      local target = {}
      api.questSession = target
      target.canStart = source.CanStart
      target.canStop = source.CanStop
      target.exists = source.Exists
      target.getAvailableSessionCommand = source.GetAvailableSessionCommand
      target.getPendingCommand = source.GetPendingCommand
      target.getProposedMaxLevelForSession = source.GetProposedMaxLevelForSession
      target.getSessionBeginDetails = source.GetSessionBeginDetails
      target.getSuperTrackedQuest = source.GetSuperTrackedQuest
      target.hasJoined = source.HasJoined
      target.hasPendingCommand = source.HasPendingCommand
      target.requestSessionStart = source.RequestSessionStart
      target.requestSessionStop = source.RequestSessionStop
      target.sendSessionBeginResponse = source.SendSessionBeginResponse
      target.setQuestIsSuperTracked = source.SetQuestIsSuperTracked
    end
  end
  do
    local source = host.C_RaidLocks
    if source then
      local target = {}
      api.raidLocks = target
      target.getRedirectedDifficultyID = source.GetRedirectedDifficultyID
      target.isEncounterComplete = source.IsEncounterComplete
      target.isRaidLockExtendFeatureEnabled = source.IsRaidLockExtendFeatureEnabled
    end
  end
  do
    local target = {}
    api.raidMarkers = target
    target.canBeRaidTarget = host.CanBeRaidTarget
    target.clearRaidMarker = host.ClearRaidMarker
    target.getRaidTargetIndex = host.GetRaidTargetIndex
    target.isRaidMarkerActive = host.IsRaidMarkerActive
    target.isRaidMarkerSystemEnabled = host.IsRaidMarkerSystemEnabled
    target.placeRaidMarker = host.PlaceRaidMarker
    target.removeRaidTargets = host.RemoveRaidTargets
    target.setRaidTarget = host.SetRaidTarget
  end
  do
    local source = host.C_RecentAllies
    if source then
      local target = {}
      api.recentAllies = target
      target.canSetRecentAllyNote = source.CanSetRecentAllyNote
      target.getRecentAllies = source.GetRecentAllies
      target.getRecentAllyByFullName = source.GetRecentAllyByFullName
      target.getRecentAllyByGUID = source.GetRecentAllyByGUID
      target.isRecentAllyByFullName = source.IsRecentAllyByFullName
      target.isRecentAllyByGUID = source.IsRecentAllyByGUID
      target.isRecentAllyDataReady = source.IsRecentAllyDataReady
      target.isRecentAllyPinned = source.IsRecentAllyPinned
      target.isSystemEnabled = source.IsSystemEnabled
      target.isSystemSupported = source.IsSystemSupported
      target.searchRecentAllies = source.SearchRecentAllies
      target.setRecentAllyNote = source.SetRecentAllyNote
      target.setRecentAllyPinned = source.SetRecentAllyPinned
      target.tryRequestRecentAlliesData = source.TryRequestRecentAlliesData
    end
  end
  do
    local source = host.C_RecruitAFriend
    if source then
      local target = {}
      api.recruitAFriend = target
      target.canSummonFriend = source.CanSummonFriend
      target.claimActivityReward = source.ClaimActivityReward
      target.claimNextReward = source.ClaimNextReward
      target.generateRecruitmentLink = source.GenerateRecruitmentLink
      target.getRAFInfo = source.GetRAFInfo
      target.getRAFSystemInfo = source.GetRAFSystemInfo
      target.getRecruitActivityRequirementsText = source.GetRecruitActivityRequirementsText
      target.getRecruitInfo = source.GetRecruitInfo
      target.getSummonFriendCooldown = source.GetSummonFriendCooldown
      target.isRecruitAFriendLinked = source.IsRecruitAFriendLinked
      target.isRecruitingEnabled = source.IsRecruitingEnabled
      target.isSystemEnabled = source.IsSystemEnabled
      target.isSystemSupported = source.IsSystemSupported
      target.removeRAFRecruit = source.RemoveRAFRecruit
      target.requestUpdatedRecruitmentInfo = source.RequestUpdatedRecruitmentInfo
      target.summonFriend = source.SummonFriend
    end
  end
  do
    local source = host.C_RemixArtifactUI
    if source then
      local target = {}
      api.remixArtifactUI = target
      target.clearRemixArtifactItem = source.ClearRemixArtifactItem
      target.getAppearanceInfoByID = source.GetAppearanceInfoByID
      target.getArtifactArtInfo = source.GetArtifactArtInfo
      target.getArtifactItemInfo = source.GetArtifactItemInfo
      target.getCurrArtifactItemID = source.GetCurrArtifactItemID
      target.getCurrItemSpecIndex = source.GetCurrItemSpecIndex
      target.getCurrTraitTreeID = source.GetCurrTraitTreeID
      target.itemInSlotIsRemixArtifact = source.ItemInSlotIsRemixArtifact
    end
  end
  do
    local source = host.C_ReportSystem
    if source then
      local target = {}
      api.reportSystem = target
      target.canReportPlayer = source.CanReportPlayer
      target.canReportPlayerForLanguage = source.CanReportPlayerForLanguage
      target.getMajorCategoriesForReportType = source.GetMajorCategoriesForReportType
      target.getMajorCategoryString = source.GetMajorCategoryString
      target.getMinorCategoriesForReportTypeAndMajorCategory =
        source.GetMinorCategoriesForReportTypeAndMajorCategory
      target.getMinorCategoryString = source.GetMinorCategoryString
      target.reportServerLag = source.ReportServerLag
      target.reportStuckInCombat = source.ReportStuckInCombat
      target.requiresScreenshotForReportType = source.RequiresScreenshotForReportType
      target.sendReport = source.SendReport
      target.setScreenshotPreviewTexture = source.SetScreenshotPreviewTexture
      target.takeReportScreenshot = source.TakeReportScreenshot
    end
  end
  do
    local source = host.C_Reputation
    if source then
      local target = {}
      api.reputation = target
      target.areLegacyReputationsShown = source.AreLegacyReputationsShown
      target.collapseAllFactionHeaders = source.CollapseAllFactionHeaders
      target.collapseFactionHeader = source.CollapseFactionHeader
      target.expandAllFactionHeaders = source.ExpandAllFactionHeaders
      target.expandFactionHeader = source.ExpandFactionHeader
      target.getFactionDataByID = source.GetFactionDataByID
      target.getFactionDataByIndex = source.GetFactionDataByIndex
      target.getFactionParagonInfo = source.GetFactionParagonInfo
      target.getGuildFactionData = source.GetGuildFactionData
      target.getGuildRepExpirationTime = source.GetGuildRepExpirationTime
      target.getNumFactions = source.GetNumFactions
      target.getReputationSortType = source.GetReputationSortType
      target.getSelectedFaction = source.GetSelectedFaction
      target.getWatchedFactionData = source.GetWatchedFactionData
      target.isAccountWideReputation = source.IsAccountWideReputation
      target.isFactionActive = source.IsFactionActive
      target.isFactionParagon = source.IsFactionParagon
      target.isFactionParagonForCurrentPlayer = source.IsFactionParagonForCurrentPlayer
      target.isMajorFaction = source.IsMajorFaction
      target.requestFactionParagonPreloadRewardData = source.RequestFactionParagonPreloadRewardData
      target.setFactionActive = source.SetFactionActive
      target.setLegacyReputationsShown = source.SetLegacyReputationsShown
      target.setReputationSortType = source.SetReputationSortType
      target.setSelectedFaction = source.SetSelectedFaction
      target.setWatchedFactionByID = source.SetWatchedFactionByID
      target.setWatchedFactionByIndex = source.SetWatchedFactionByIndex
      target.toggleFactionAtWar = source.ToggleFactionAtWar
    end
  end
  do
    local source = host.C_ResearchInfo
    if source then
      local target = {}
      api.researchInfo = target
      target.getDigSitesForMap = source.GetDigSitesForMap
    end
  end
  do
    local source = host.C_RestrictedActions
    local target = {}
    if source then
      target.checkAllowProtectedFunctions = source.CheckAllowProtectedFunctions
      target.getAddOnRestrictionState = source.GetAddOnRestrictionState
      target.isAddOnRestrictionActive = source.IsAddOnRestrictionActive
    end
    target.inCombatLockdown = host.InCombatLockdown
    if source or next(target) then
      api.restrictedActions = target
    end
  end
  do
    local source = host.C_Roleset
    if source then
      local target = {}
      api.roleset = target
      target.applyRolesetFilters = source.ApplyRolesetFilters
      target.getActiveAllowedRolesets = source.GetActiveAllowedRolesets
      target.getActiveBlockedRolesets = source.GetActiveBlockedRolesets
    end
  end
  do
    local source = host.C_ScenarioInfo
    if source then
      local target = {}
      api.scenarioInfo = target
      target.getCriteriaInfo = source.GetCriteriaInfo
      target.getCriteriaInfoByStep = source.GetCriteriaInfoByStep
      target.getDisplayInfo = source.GetDisplayInfo
      target.getJailersTowerTypeString = source.GetJailersTowerTypeString
      target.getScenarioIconInfo = source.GetScenarioIconInfo
      target.getScenarioInfo = source.GetScenarioInfo
      target.getScenarioStepInfo = source.GetScenarioStepInfo
      target.getTieredEntranceActiveSpells = source.GetTieredEntranceActiveSpells
      target.getUnitCriteriaProgressValues = source.GetUnitCriteriaProgressValues
      target.isTieredEntranceScenario = source.IsTieredEntranceScenario
    end
  end
  do
    local source = host.C_ScrappingMachineUI
    if source then
      local target = {}
      api.scrappingMachineUI = target
      target.closeScrappingMachine = source.CloseScrappingMachine
      target.dropPendingScrapItemFromCursor = source.DropPendingScrapItemFromCursor
      target.getCurrentPendingScrapItemLocationByIndex =
        source.GetCurrentPendingScrapItemLocationByIndex
      target.getScrapSpellID = source.GetScrapSpellID
      target.getScrappingMachineName = source.GetScrappingMachineName
      target.hasScrappableItems = source.HasScrappableItems
      target.removeAllScrapItems = source.RemoveAllScrapItems
      target.removeCurrentScrappingItem = source.RemoveCurrentScrappingItem
      target.removeItemToScrap = source.RemoveItemToScrap
      target.scrapItems = source.ScrapItems
      target.validateScrappingList = source.ValidateScrappingList
    end
  end
  do
    local target = {}
    api.screen = target
    target.getDefaultScale = host.GetDefaultScale
    target.getPhysicalScreenSize = host.GetPhysicalScreenSize
    target.getScreenDPIScale = host.GetScreenDPIScale
    target.getScreenHeight = host.GetScreenHeight
    target.getScreenWidth = host.GetScreenWidth
  end
  do
    local source = host.C_ScriptWarnings
    if source then
      local target = {}
      api.scriptWarnings = target
    end
  end
  do
    local source = host.C_ScriptedAnimations
    if source then
      local target = {}
      api.scriptedAnimations = target
      target.getAllScriptedAnimationEffects = source.GetAllScriptedAnimationEffects
    end
  end
  do
    local source = host.C_SeasonInfo
    if source then
      local target = {}
      api.seasonInfo = target
      target.getCurrentDisplaySeasonExpansion = source.GetCurrentDisplaySeasonExpansion
      target.getCurrentDisplaySeasonID = source.GetCurrentDisplaySeasonID
    end
  end
  do
    local source = host.C_Secrets
    if source then
      local target = {}
      api.secrets = target
      target.canCompareUnitTokens = source.CanCompareUnitTokens
      target.getPowerTypeSecrecy = source.GetPowerTypeSecrecy
      target.getSpellAuraSecrecy = source.GetSpellAuraSecrecy
      target.getSpellCastSecrecy = source.GetSpellCastSecrecy
      target.getSpellCooldownSecrecy = source.GetSpellCooldownSecrecy
      target.hasSecretRestrictions = source.HasSecretRestrictions
      target.shouldActionCooldownBeSecret = source.ShouldActionCooldownBeSecret
      target.shouldAurasBeSecret = source.ShouldAurasBeSecret
      target.shouldCooldownsBeSecret = source.ShouldCooldownsBeSecret
      target.shouldSpellAuraBeSecret = source.ShouldSpellAuraBeSecret
      target.shouldSpellBookItemCooldownBeSecret = source.ShouldSpellBookItemCooldownBeSecret
      target.shouldSpellCooldownBeSecret = source.ShouldSpellCooldownBeSecret
      target.shouldTotemSlotBeSecret = source.ShouldTotemSlotBeSecret
      target.shouldTotemSpellBeSecret = source.ShouldTotemSpellBeSecret
      target.shouldUnitAuraIndexBeSecret = source.ShouldUnitAuraIndexBeSecret
      target.shouldUnitAuraInstanceBeSecret = source.ShouldUnitAuraInstanceBeSecret
      target.shouldUnitAuraSlotBeSecret = source.ShouldUnitAuraSlotBeSecret
      target.shouldUnitComparisonBeSecret = source.ShouldUnitComparisonBeSecret
      target.shouldUnitHealthMaxBeSecret = source.ShouldUnitHealthMaxBeSecret
      target.shouldUnitIdentityBeSecret = source.ShouldUnitIdentityBeSecret
      target.shouldUnitPowerBeSecret = source.ShouldUnitPowerBeSecret
      target.shouldUnitPowerMaxBeSecret = source.ShouldUnitPowerMaxBeSecret
      target.shouldUnitSpellCastBeSecret = source.ShouldUnitSpellCastBeSecret
      target.shouldUnitSpellCastingBeSecret = source.ShouldUnitSpellCastingBeSecret
      target.shouldUnitStatsBeSecret = source.ShouldUnitStatsBeSecret
      target.shouldUnitThreatStateBeSecret = source.ShouldUnitThreatStateBeSecret
      target.shouldUnitThreatValuesBeSecret = source.ShouldUnitThreatValuesBeSecret
    end
  end
  do
    local source = host.C_SecureTransfer
    if source then
      local target = {}
      api.secureTransfer = target
      target.acceptTrade = source.AcceptTrade
      target.cancel = source.Cancel
      target.completeHousingPurchase = source.CompleteHousingPurchase
      target.completeHousingVCPurchase = source.CompleteHousingVCPurchase
      target.getHousingPurchaseCost = source.GetHousingPurchaseCost
      target.getHousingPurchaseQuantity = source.GetHousingPurchaseQuantity
      target.getHousingVCPurchaseProductID = source.GetHousingVCPurchaseProductID
      target.getMailInfo = source.GetMailInfo
      target.getTradePartner = source.GetTradePartner
      target.sendMail = source.SendMail
      target.shouldShowTradeOfferWarning = source.ShouldShowTradeOfferWarning
    end
  end
  do
    local source = host.C_SettingsUtil
    if source then
      local target = {}
      api.settingsUtil = target
      target.notifySettingsLoaded = source.NotifySettingsLoaded
      target.openSettingsPanel = source.OpenSettingsPanel
    end
  end
  do
    local source = host.C_SkillInfo
    if source then
      local target = {}
      api.skillInfo = target
    end
  end
  do
    local target = {}
    api.slashCommand = target
    target.areDangerousScriptsAllowed = host.AreDangerousScriptsAllowed
    target.setAllowDangerousScripts = host.SetAllowDangerousScripts
  end
  do
    local source = host.C_SocialQueue
    if source then
      local target = {}
      api.socialQueue = target
      target.getAllGroups = source.GetAllGroups
      target.getConfig = source.GetConfig
      target.getGroupForPlayer = source.GetGroupForPlayer
      target.getGroupInfo = source.GetGroupInfo
      target.getGroupMembers = source.GetGroupMembers
      target.getGroupQueues = source.GetGroupQueues
      target.isSystemEnabled = source.IsSystemEnabled
      target.isSystemSupported = source.IsSystemSupported
      target.requestToJoin = source.RequestToJoin
      target.signalToastDisplayed = source.SignalToastDisplayed
    end
  end
  do
    local source = host.C_SocialRestrictions
    if source then
      local target = {}
      api.socialRestrictions = target
      target.acknowledgeRegionalChatDisabled = source.AcknowledgeRegionalChatDisabled
      target.canReceiveChat = source.CanReceiveChat
      target.canSendChat = source.CanSendChat
      target.isChatDisabled = source.IsChatDisabled
      target.isFriendsDisabled = source.IsFriendsDisabled
      target.isMuted = source.IsMuted
      target.isSilenced = source.IsSilenced
      target.isSquelched = source.IsSquelched
      target.setChatDisabled = source.SetChatDisabled
    end
  end
  do
    local source = host.C_SocialUI
    if source then
      local target = {}
      api.socialUI = target
      target.isSystemEnabled = source.IsSystemEnabled
    end
  end
  do
    local source = host.C_Soulbinds
    if source then
      local target = {}
      api.soulbinds = target
      target.activateSoulbind = source.ActivateSoulbind
      target.canActivateSoulbind = source.CanActivateSoulbind
      target.canModifySoulbind = source.CanModifySoulbind
      target.canResetConduitsInSoulbind = source.CanResetConduitsInSoulbind
      target.canSwitchActiveSoulbindTreeBranch = source.CanSwitchActiveSoulbindTreeBranch
      target.closeUI = source.CloseUI
      target.commitPendingConduitsInSoulbind = source.CommitPendingConduitsInSoulbind
      target.findNodeIDActuallyInstalled = source.FindNodeIDActuallyInstalled
      target.findNodeIDAppearingInstalled = source.FindNodeIDAppearingInstalled
      target.findNodeIDPendingInstall = source.FindNodeIDPendingInstall
      target.findNodeIDPendingUninstall = source.FindNodeIDPendingUninstall
      target.getActiveSoulbindID = source.GetActiveSoulbindID
      target.getConduitCollection = source.GetConduitCollection
      target.getConduitCollectionCount = source.GetConduitCollectionCount
      target.getConduitCollectionData = source.GetConduitCollectionData
      target.getConduitCollectionDataAtCursor = source.GetConduitCollectionDataAtCursor
      target.getConduitCollectionDataByVirtualID = source.GetConduitCollectionDataByVirtualID
      target.getConduitDisplayed = source.GetConduitDisplayed
      target.getConduitHyperlink = source.GetConduitHyperlink
      target.getConduitIDPendingInstall = source.GetConduitIDPendingInstall
      target.getConduitQuality = source.GetConduitQuality
      target.getConduitRank = source.GetConduitRank
      target.getConduitSpellID = source.GetConduitSpellID
      target.getInstalledConduitID = source.GetInstalledConduitID
      target.getNode = source.GetNode
      target.getSoulbindData = source.GetSoulbindData
      target.getSpecsAssignedToSoulbind = source.GetSpecsAssignedToSoulbind
      target.getTree = source.GetTree
      target.hasAnyInstalledConduitInSoulbind = source.HasAnyInstalledConduitInSoulbind
      target.hasAnyPendingConduits = source.HasAnyPendingConduits
      target.hasPendingConduitsInSoulbind = source.HasPendingConduitsInSoulbind
      target.isConduitInstalled = source.IsConduitInstalled
      target.isConduitInstalledInSoulbind = source.IsConduitInstalledInSoulbind
      target.isItemConduitByItemInfo = source.IsItemConduitByItemInfo
      target.isNodePendingModify = source.IsNodePendingModify
      target.isUnselectedConduitPendingInSoulbind = source.IsUnselectedConduitPendingInSoulbind
      target.modifyNode = source.ModifyNode
      target.selectNode = source.SelectNode
      target.unmodifyNode = source.UnmodifyNode
    end
  end
  do
    local source = host.C_Sound
    if source then
      local target = {}
      api.sound = target
      target.getSoundScaledVolume = source.GetSoundScaledVolume
      target.isPlaying = source.IsPlaying
      target.playItemSound = source.PlayItemSound
      target.playSound = source.PlaySound
      target.playSoundWithOptions = source.PlaySoundWithOptions
      target.playVocalErrorSound = source.PlayVocalErrorSound
    end
  end
  do
    local source = host.C_SpecializationInfo
    if source then
      local target = {}
      api.specializationInfo = target
      target.canPlayerUsePVPTalentUI = source.CanPlayerUsePVPTalentUI
      target.canPlayerUseTalentSpecUI = source.CanPlayerUseTalentSpecUI
      target.canPlayerUseTalentUI = source.CanPlayerUseTalentUI
      target.getActiveSpecGroup = source.GetActiveSpecGroup
      target.getAllSelectedPvpTalentIDs = source.GetAllSelectedPvpTalentIDs
      target.getClassIDFromSpecID = source.GetClassIDFromSpecID
      target.getInspectSelectedPvpTalent = source.GetInspectSelectedPvpTalent
      target.getInspectSpecialization = source.GetInspectSpecialization
      target.getNumSpecializationsForClassID = source.GetNumSpecializationsForClassID
      target.getPvpTalentAlertStatus = source.GetPvpTalentAlertStatus
      target.getPvpTalentInfo = source.GetPvpTalentInfo
      target.getPvpTalentSlotInfo = source.GetPvpTalentSlotInfo
      target.getPvpTalentSlotUnlockLevel = source.GetPvpTalentSlotUnlockLevel
      target.getPvpTalentUnlockLevel = source.GetPvpTalentUnlockLevel
      target.getSpecIDs = source.GetSpecIDs
      target.getSpecialization = source.GetSpecialization
      target.getSpecializationInfo = source.GetSpecializationInfo
      target.getSpecializationMasterySpells = source.GetSpecializationMasterySpells
      target.getSpellsDisplay = source.GetSpellsDisplay
      target.getTalentInfo = source.GetTalentInfo
      target.isInitialized = source.IsInitialized
      target.isPvpTalentLocked = source.IsPvpTalentLocked
      target.matchesCurrentSpecSet = source.MatchesCurrentSpecSet
      target.setPetSpecialization = source.SetPetSpecialization
      target.setPvpTalentLocked = source.SetPvpTalentLocked
      target.setSpecialization = source.SetSpecialization
    end
  end
  do
    local target = {}
    api.specializationShared = target
    target.getSpecializationInfoForClassID = host.GetSpecializationInfoForClassID
    target.getSpecializationInfoForSpecID = host.GetSpecializationInfoForSpecID
    target.getSpecializationNameForSpecID = host.GetSpecializationNameForSpecID
    target.getSpecializationSystem = host.GetSpecializationSystem
    target.hasLootSpecializations = host.HasLootSpecializations
  end
  do
    local source = host.C_Spell
    if source then
      local target = {}
      api.spell = target
      target.cancelSpellByID = source.CancelSpellByID
      target.doesSpellExist = source.DoesSpellExist
      target.enableSpellRangeCheck = source.EnableSpellRangeCheck
      target.getAuraStatChanges = source.GetAuraStatChanges
      target.getBaseSpell = source.GetBaseSpell
      target.getDeadlyDebuffInfo = source.GetDeadlyDebuffInfo
      target.getItemModifiedAppearancesApplied = source.GetItemModifiedAppearancesApplied
      target.getLastCategoryCooldownSource = source.GetLastCategoryCooldownSource
      target.getMawPowerLinkBySpellID = source.GetMawPowerLinkBySpellID
      target.getMawPowerRarityInfoBySpellID = source.GetMawPowerRarityInfoBySpellID
      target.getOverrideSpell = source.GetOverrideSpell
      target.getSchoolString = source.GetSchoolString
      target.getSpellAutoCast = source.GetSpellAutoCast
      target.getSpellCastCount = source.GetSpellCastCount
      target.getSpellChargeDuration = source.GetSpellChargeDuration
      target.getSpellCharges = source.GetSpellCharges
      target.getSpellCooldown = source.GetSpellCooldown
      target.getSpellCooldownDuration = source.GetSpellCooldownDuration
      target.getSpellDescription = source.GetSpellDescription
      target.getSpellDescriptionForItemLocation = source.GetSpellDescriptionForItemLocation
      target.getSpellDisplayCount = source.GetSpellDisplayCount
      target.getSpellIDForSpellIdentifier = source.GetSpellIDForSpellIdentifier
      target.getSpellInfo = source.GetSpellInfo
      target.getSpellLevelLearned = source.GetSpellLevelLearned
      target.getSpellLink = source.GetSpellLink
      target.getSpellLossOfControlCooldownDuration = source.GetSpellLossOfControlCooldownDuration
      target.getSpellLossOfControlCooldownInfo = source.GetSpellLossOfControlCooldownInfo
      target.getSpellMaxCumulativeAuraApplications = source.GetSpellMaxCumulativeAuraApplications
      target.getSpellName = source.GetSpellName
      target.getSpellPowerCost = source.GetSpellPowerCost
      target.getSpellQueueWindow = source.GetSpellQueueWindow
      target.getSpellSkillLineAbilityRank = source.GetSpellSkillLineAbilityRank
      target.getSpellSubtext = source.GetSpellSubtext
      target.getSpellTexture = source.GetSpellTexture
      target.getSpellTradeSkillLink = source.GetSpellTradeSkillLink
      target.getVisibilityInfo = source.GetVisibilityInfo
      target.isAutoAttackSpell = source.IsAutoAttackSpell
      target.isAutoRepeatSpell = source.IsAutoRepeatSpell
      target.isClassTalentSpell = source.IsClassTalentSpell
      target.isConsumableSpell = source.IsConsumableSpell
      target.isCurrentSpell = source.IsCurrentSpell
      target.isExternalDefensive = source.IsExternalDefensive
      target.isPressHoldReleaseSpell = source.IsPressHoldReleaseSpell
      target.isPriorityAura = source.IsPriorityAura
      target.isPvPTalentSpell = source.IsPvPTalentSpell
      target.isRangedAutoAttackSpell = source.IsRangedAutoAttackSpell
      target.isSelfBuff = source.IsSelfBuff
      target.isSpellCrowdControl = source.IsSpellCrowdControl
      target.isSpellDataCached = source.IsSpellDataCached
      target.isSpellDisabled = source.IsSpellDisabled
      target.isSpellHarmful = source.IsSpellHarmful
      target.isSpellHelpful = source.IsSpellHelpful
      target.isSpellImportant = source.IsSpellImportant
      target.isSpellInRange = source.IsSpellInRange
      target.isSpellPassive = source.IsSpellPassive
      target.isSpellUsable = source.IsSpellUsable
      target.pickupSpell = source.PickupSpell
      target.requestLoadSpellData = source.RequestLoadSpellData
      target.setSpellAutoCastEnabled = source.SetSpellAutoCastEnabled
      target.spellHasRange = source.SpellHasRange
      target.targetSpellChecksItemCondition = source.TargetSpellChecksItemCondition
      target.targetSpellIsEnchanting = source.TargetSpellIsEnchanting
      target.targetSpellJumpsUpgradeTrack = source.TargetSpellJumpsUpgradeTrack
      target.targetSpellReplacesBonusTree = source.TargetSpellReplacesBonusTree
      target.toggleSpellAutoCast = source.ToggleSpellAutoCast
    end
  end
  do
    local source = host.C_SpellActivationOverlay
    if source then
      local target = {}
      api.spellActivationOverlay = target
      target.isSpellOverlayed = source.IsSpellOverlayed
    end
  end
  do
    local source = host.C_SpellBook
    if source then
      local target = {}
      api.spellBook = target
      target.castSpellBookItem = source.CastSpellBookItem
      target.containsAnyDisenchantSpell = source.ContainsAnyDisenchantSpell
      target.findBaseSpellByID = source.FindBaseSpellByID
      target.findFlyoutSlotBySpellID = source.FindFlyoutSlotBySpellID
      target.findSpellBookSlotForSpell = source.FindSpellBookSlotForSpell
      target.findSpellOverrideByID = source.FindSpellOverrideByID
      target.getCurrentLevelSpells = source.GetCurrentLevelSpells
      target.getNumSpellBookSkillLines = source.GetNumSpellBookSkillLines
      target.getSkillLineIndexByID = source.GetSkillLineIndexByID
      target.getSpellBookItemAutoCast = source.GetSpellBookItemAutoCast
      target.getSpellBookItemCastCount = source.GetSpellBookItemCastCount
      target.getSpellBookItemChargeDuration = source.GetSpellBookItemChargeDuration
      target.getSpellBookItemCharges = source.GetSpellBookItemCharges
      target.getSpellBookItemCooldown = source.GetSpellBookItemCooldown
      target.getSpellBookItemCooldownDuration = source.GetSpellBookItemCooldownDuration
      target.getSpellBookItemDescription = source.GetSpellBookItemDescription
      target.getSpellBookItemInfo = source.GetSpellBookItemInfo
      target.getSpellBookItemLevelLearned = source.GetSpellBookItemLevelLearned
      target.getSpellBookItemLink = source.GetSpellBookItemLink
      target.getSpellBookItemLossOfControlCooldownDuration =
        source.GetSpellBookItemLossOfControlCooldownDuration
      target.getSpellBookItemLossOfControlCooldownInfo =
        source.GetSpellBookItemLossOfControlCooldownInfo
      target.getSpellBookItemName = source.GetSpellBookItemName
      target.getSpellBookItemPowerCost = source.GetSpellBookItemPowerCost
      target.getSpellBookItemSkillLineIndex = source.GetSpellBookItemSkillLineIndex
      target.getSpellBookItemTexture = source.GetSpellBookItemTexture
      target.getSpellBookItemTradeSkillLink = source.GetSpellBookItemTradeSkillLink
      target.getSpellBookItemType = source.GetSpellBookItemType
      target.getSpellBookSkillLineInfo = source.GetSpellBookSkillLineInfo
      target.hasPetSpells = source.HasPetSpells
      target.isAutoAttackSpellBookItem = source.IsAutoAttackSpellBookItem
      target.isClassTalentSpellBookItem = source.IsClassTalentSpellBookItem
      target.isPvPTalentSpellBookItem = source.IsPvPTalentSpellBookItem
      target.isRangedAutoAttackSpellBookItem = source.IsRangedAutoAttackSpellBookItem
      target.isSpellBookItemHarmful = source.IsSpellBookItemHarmful
      target.isSpellBookItemHelpful = source.IsSpellBookItemHelpful
      target.isSpellBookItemInRange = source.IsSpellBookItemInRange
      target.isSpellBookItemOffSpec = source.IsSpellBookItemOffSpec
      target.isSpellBookItemPassive = source.IsSpellBookItemPassive
      target.isSpellBookItemUsable = source.IsSpellBookItemUsable
      target.isSpellInSpellBook = source.IsSpellInSpellBook
      target.isSpellKnown = source.IsSpellKnown
      target.isSpellKnownOrInSpellBook = source.IsSpellKnownOrInSpellBook
      target.pickupSpellBookItem = source.PickupSpellBookItem
      target.setSpellBookItemAutoCastEnabled = source.SetSpellBookItemAutoCastEnabled
      target.spellBookItemHasRange = source.SpellBookItemHasRange
      target.toggleSpellBookItemAutoCast = source.ToggleSpellBookItemAutoCast
    end
  end
  do
    local source = host.C_SpellDiminish
    if source then
      local target = {}
      api.spellDiminish = target
      target.getAllSpellDiminishCategories = source.GetAllSpellDiminishCategories
      target.getSpellDiminishCategoryInfo = source.GetSpellDiminishCategoryInfo
      target.isSystemSupported = source.IsSystemSupported
      target.shouldTrackSpellDiminishCategory = source.ShouldTrackSpellDiminishCategory
    end
  end
  do
    local source = host.C_SplashScreen
    if source then
      local target = {}
      api.splashScreen = target
      target.acknowledgeSplash = source.AcknowledgeSplash
      target.canViewSplashScreen = source.CanViewSplashScreen
      target.requestLatestSplashScreen = source.RequestLatestSplashScreen
      target.sendSplashScreenActionLaunchedTelem = source.SendSplashScreenActionLaunchedTelem
      target.sendSplashScreenCloseTelem = source.SendSplashScreenCloseTelem
    end
  end
  do
    local source = host.C_StableInfo
    if source then
      local target = {}
      api.stableInfo = target
      target.closePetStables = source.ClosePetStables
      target.getActivePetList = source.GetActivePetList
      target.getAvailablePetSpecInfos = source.GetAvailablePetSpecInfos
      target.getNumActivePets = source.GetNumActivePets
      target.getNumStablePets = source.GetNumStablePets
      target.getStablePetFoodTypes = source.GetStablePetFoodTypes
      target.getStablePetInfo = source.GetStablePetInfo
      target.getStabledPetList = source.GetStabledPetList
      target.isAtStableMaster = source.IsAtStableMaster
      target.isBonusPetSlotAvailable = source.IsBonusPetSlotAvailable
      target.isPetFavorite = source.IsPetFavorite
      target.pickupStablePet = source.PickupStablePet
      target.setPetFavorite = source.SetPetFavorite
      target.setPetSlot = source.SetPetSlot
    end
  end
  do
    local source = host.C_StorePublic
    if source then
      local target = {}
      api.storePublic = target
      target.doesGroupHavePurchaseableProducts = source.DoesGroupHavePurchaseableProducts
      target.eventStoreUISetShown = source.EventStoreUISetShown
      target.isEnabled = source.IsEnabled
    end
  end
  do
    local target = {}
    api.streaming = target
    target.getAvailableBandwidth = host.GetAvailableBandwidth
    target.getBackgroundLoadingStatus = host.GetBackgroundLoadingStatus
    target.getDownloadedPercentage = host.GetDownloadedPercentage
    target.getFileStreamingStatus = host.GetFileStreamingStatus
  end
  do
    local source = host.C_StringUtil
    local target = {}
    if source then
      target.createAbbreviatedNumberFormatter = source.CreateAbbreviatedNumberFormatter
      target.createNumericRuleFormatter = source.CreateNumericRuleFormatter
      target.createSecondsFormatter = source.CreateSecondsFormatter
      target.escapeDecimalNonPrintables = source.EscapeDecimalNonPrintables
      target.escapeLuaFormatString = source.EscapeLuaFormatString
      target.escapeLuaPatterns = source.EscapeLuaPatterns
      target.escapeQuotedCodes = source.EscapeQuotedCodes
      target.floorToNearestString = source.FloorToNearestString
      target.removeContiguousSpaces = source.RemoveContiguousSpaces
      target.roundToNearestString = source.RoundToNearestString
      target.stripHyperlinks = source.StripHyperlinks
      target.stripTextureMarkupForLooseFiles = source.StripTextureMarkupForLooseFiles
      target.truncateWhenZero = source.TruncateWhenZero
      target.wrapString = source.WrapString
    end
    do
      local elsewhere = host.string
      if elsewhere then
        target.trim = elsewhere.trim
      end
    end
    if source or next(target) then
      api.stringUtil = target
    end
  end
  do
    local source = host.C_SummonInfo
    if source then
      local target = {}
      api.summonInfo = target
      target.cancelSummon = source.CancelSummon
      target.confirmSummon = source.ConfirmSummon
      target.getSummonConfirmAreaName = source.GetSummonConfirmAreaName
      target.getSummonConfirmSummoner = source.GetSummonConfirmSummoner
      target.getSummonConfirmTimeLeft = source.GetSummonConfirmTimeLeft
      target.getSummonReason = source.GetSummonReason
      target.isSummonSkippingStartExperience = source.IsSummonSkippingStartExperience
    end
  end
  do
    local source = host.C_SuperTrack
    if source then
      local target = {}
      api.superTrack = target
      target.clearAllSuperTracked = source.ClearAllSuperTracked
      target.clearSuperTrackedContent = source.ClearSuperTrackedContent
      target.clearSuperTrackedMapPin = source.ClearSuperTrackedMapPin
      target.getHighestPrioritySuperTrackingType = source.GetHighestPrioritySuperTrackingType
      target.getSuperTrackedContent = source.GetSuperTrackedContent
      target.getSuperTrackedItemName = source.GetSuperTrackedItemName
      target.getSuperTrackedMapPin = source.GetSuperTrackedMapPin
      target.getSuperTrackedQuestID = source.GetSuperTrackedQuestID
      target.getSuperTrackedVignette = source.GetSuperTrackedVignette
      target.isSuperTrackingAnything = source.IsSuperTrackingAnything
      target.isSuperTrackingContent = source.IsSuperTrackingContent
      target.isSuperTrackingCorpse = source.IsSuperTrackingCorpse
      target.isSuperTrackingMapPin = source.IsSuperTrackingMapPin
      target.isSuperTrackingQuest = source.IsSuperTrackingQuest
      target.isSuperTrackingUserWaypoint = source.IsSuperTrackingUserWaypoint
      target.setSuperTrackedContent = source.SetSuperTrackedContent
      target.setSuperTrackedMapPin = source.SetSuperTrackedMapPin
      target.setSuperTrackedQuestID = source.SetSuperTrackedQuestID
      target.setSuperTrackedUserWaypoint = source.SetSuperTrackedUserWaypoint
      target.setSuperTrackedVignette = source.SetSuperTrackedVignette
    end
  end
  do
    local source = host.C_System
    if source then
      local target = {}
      api.system = target
      target.getFrameStack = source.GetFrameStack
    end
  end
  do
    local target = {}
    api.systemTime = target
    target.getGameTime = host.GetGameTime
    target.getLocalGameTime = host.GetLocalGameTime
    target.getServerTime = host.GetServerTime
    target.getSessionTime = host.GetSessionTime
    target.getTickTime = host.GetTickTime
    target.getTime = host.GetTime
    target.isUsingFixedTimeStep = host.IsUsingFixedTimeStep
  end
  do
    local source = host.C_SystemVisibilityManager
    if source then
      local target = {}
      api.systemVisibilityManager = target
      target.isSystemVisible = source.IsSystemVisible
    end
  end
  do
    local source = host.C_TableUtil
    local target = {}
    if source then
      target.findIndexedMismatch = source.FindIndexedMismatch
    end
    do
      local elsewhere = host.table
      if elsewhere then
        target.count = elsewhere.count
        target.create = elsewhere.create
        target.freeze = elsewhere.freeze
        target.isfrozen = elsewhere.isfrozen
      end
    end
    if source or next(target) then
      api.tableUtil = target
    end
  end
  do
    local source = host.C_TalkingHead
    if source then
      local target = {}
      api.talkingHead = target
    end
  end
  do
    local target = {}
    api.targetScript = target
    target.assistUnit = host.AssistUnit
    target.attackTarget = host.AttackTarget
    target.clearFocus = host.ClearFocus
    target.clearTarget = host.ClearTarget
    target.focusUnit = host.FocusUnit
    target.isTargetLoose = host.IsTargetLoose
    target.targetDirectionEnemy = host.TargetDirectionEnemy
    target.targetDirectionFinished = host.TargetDirectionFinished
    target.targetDirectionFriend = host.TargetDirectionFriend
    target.targetLastEnemy = host.TargetLastEnemy
    target.targetLastFriend = host.TargetLastFriend
    target.targetLastTarget = host.TargetLastTarget
    target.targetNearest = host.TargetNearest
    target.targetNearestEnemy = host.TargetNearestEnemy
    target.targetNearestEnemyPlayer = host.TargetNearestEnemyPlayer
    target.targetNearestFriend = host.TargetNearestFriend
    target.targetNearestFriendPlayer = host.TargetNearestFriendPlayer
    target.targetNearestPartyMember = host.TargetNearestPartyMember
    target.targetNearestRaidMember = host.TargetNearestRaidMember
    target.targetPriorityHighlightEnd = host.TargetPriorityHighlightEnd
    target.targetPriorityHighlightStart = host.TargetPriorityHighlightStart
    target.targetToggle = host.TargetToggle
    target.targetUnit = host.TargetUnit
  end
  do
    local source = host.C_TaskQuest
    if source then
      local target = {}
      api.taskQuest = target
      target.doesMapShowTaskQuestObjectives = source.DoesMapShowTaskQuestObjectives
      target.getQuestInfoByQuestID = source.GetQuestInfoByQuestID
      target.getQuestLocation = source.GetQuestLocation
      target.getQuestProgressBarInfo = source.GetQuestProgressBarInfo
      target.getQuestTimeLeftMinutes = source.GetQuestTimeLeftMinutes
      target.getQuestTimeLeftSeconds = source.GetQuestTimeLeftSeconds
      target.getQuestUIWidgetSetByType = source.GetQuestUIWidgetSetByType
      target.getQuestZoneID = source.GetQuestZoneID
      target.getQuestsOnMap = source.GetQuestsOnMap
      target.getThreatQuests = source.GetThreatQuests
      target.isActive = source.IsActive
      target.requestPreloadRewardData = source.RequestPreloadRewardData
    end
  end
  do
    local source = host.C_TaxiMap
    if source then
      local target = {}
      api.taxiMap = target
      target.getAllTaxiNodes = source.GetAllTaxiNodes
      target.getTaxiNodesForMap = source.GetTaxiNodesForMap
      target.shouldMapShowTaxiNodes = source.ShouldMapShowTaxiNodes
    end
  end
  do
    local source = host.C_Texture
    if source then
      local target = {}
      api.texture = target
      target.clearTitleIconTexture = source.ClearTitleIconTexture
      target.getAtlasElementID = source.GetAtlasElementID
      target.getAtlasElements = source.GetAtlasElements
      target.getAtlasExists = source.GetAtlasExists
      target.getAtlasID = source.GetAtlasID
      target.getAtlasInfo = source.GetAtlasInfo
      target.getFilenameFromFileDataID = source.GetFilenameFromFileDataID
      target.getTitleIconTexture = source.GetTitleIconTexture
      target.isTitleIconTextureReady = source.IsTitleIconTextureReady
      target.setTitleIconTexture = source.SetTitleIconTexture
      target.setURLTexture = source.SetURLTexture
    end
  end
  do
    local target = {}
    api.threat = target
    target.getThreatStatusColor = host.GetThreatStatusColor
    target.isThreatWarningEnabled = host.IsThreatWarningEnabled
  end
  do
    local source = host.C_Timer
    if source then
      local target = {}
      api.timer = target
      target.after = source.After
      target.newTicker = source.NewTicker
      target.newTimer = source.NewTimer
    end
  end
  do
    local source = host.C_TimerunningUI
    if source then
      local target = {}
      api.timerunningUI = target
      target.getActiveTimerunningSeasonID = source.GetActiveTimerunningSeasonID
    end
  end
  do
    local target = {}
    api.title = target
    target.getCurrentTitle = host.GetCurrentTitle
    target.getNumTitles = host.GetNumTitles
    target.getTitleName = host.GetTitleName
    target.isTitleKnown = host.IsTitleKnown
    target.setCurrentTitle = host.SetCurrentTitle
  end
  do
    local source = host.C_TooltipComparison
    if source then
      local target = {}
      api.tooltipComparison = target
      target.compareItem = source.CompareItem
      target.getItemComparisonDelta = source.GetItemComparisonDelta
      target.getItemComparisonInfo = source.GetItemComparisonInfo
    end
  end
  do
    local source = host.C_TooltipInfo
    if source then
      local target = {}
      api.tooltipInfo = target
      target.getAchievementByID = source.GetAchievementByID
      target.getAction = source.GetAction
      target.getArtifactItem = source.GetArtifactItem
      target.getArtifactPowerByID = source.GetArtifactPowerByID
      target.getAzeriteEssence = source.GetAzeriteEssence
      target.getAzeriteEssenceSlot = source.GetAzeriteEssenceSlot
      target.getAzeritePower = source.GetAzeritePower
      target.getBackpackToken = source.GetBackpackToken
      target.getBagItem = source.GetBagItem
      target.getBagItemChild = source.GetBagItemChild
      target.getBuybackItem = source.GetBuybackItem
      target.getCompanionPet = source.GetCompanionPet
      target.getConduit = source.GetConduit
      target.getCurrencyByID = source.GetCurrencyByID
      target.getCurrencyToken = source.GetCurrencyToken
      target.getEnhancedConduit = source.GetEnhancedConduit
      target.getEquipmentSet = source.GetEquipmentSet
      target.getExistingSocketGem = source.GetExistingSocketGem
      target.getGuildBankItem = source.GetGuildBankItem
      target.getHeirloomByItemID = source.GetHeirloomByItemID
      target.getHyperlink = source.GetHyperlink
      target.getInboxItem = source.GetInboxItem
      target.getInstanceLockEncountersComplete = source.GetInstanceLockEncountersComplete
      target.getInventoryItem = source.GetInventoryItem
      target.getInventoryItemByID = source.GetInventoryItemByID
      target.getItemByGUID = source.GetItemByGUID
      target.getItemByID = source.GetItemByID
      target.getItemByItemModifiedAppearanceID = source.GetItemByItemModifiedAppearanceID
      target.getItemInteractionItem = source.GetItemInteractionItem
      target.getItemKey = source.GetItemKey
      target.getLFGDungeonReward = source.GetLFGDungeonReward
      target.getLFGDungeonShortageReward = source.GetLFGDungeonShortageReward
      target.getLootCurrency = source.GetLootCurrency
      target.getLootItem = source.GetLootItem
      target.getLootRollItem = source.GetLootRollItem
      target.getMerchantCostItem = source.GetMerchantCostItem
      target.getMerchantItem = source.GetMerchantItem
      target.getMinimapMouseover = source.GetMinimapMouseover
      target.getMountBySpellID = source.GetMountBySpellID
      target.getOutfit = source.GetOutfit
      target.getOwnedItemByID = source.GetOwnedItemByID
      target.getPetAction = source.GetPetAction
      target.getPossession = source.GetPossession
      target.getPvpBrawl = source.GetPvpBrawl
      target.getPvpTalent = source.GetPvpTalent
      target.getQuestCurrency = source.GetQuestCurrency
      target.getQuestItem = source.GetQuestItem
      target.getQuestLogCurrency = source.GetQuestLogCurrency
      target.getQuestLogItem = source.GetQuestLogItem
      target.getQuestLogSpecialItem = source.GetQuestLogSpecialItem
      target.getQuestPartyProgress = source.GetQuestPartyProgress
      target.getRecipeRankInfo = source.GetRecipeRankInfo
      target.getRecipeReagentItem = source.GetRecipeReagentItem
      target.getRecipeResultItem = source.GetRecipeResultItem
      target.getRecipeResultItemForOrder = source.GetRecipeResultItemForOrder
      target.getRuneforgeResultItem = source.GetRuneforgeResultItem
      target.getSendMailItem = source.GetSendMailItem
      target.getShapeshift = source.GetShapeshift
      target.getSlottedKeystone = source.GetSlottedKeystone
      target.getSocketGem = source.GetSocketGem
      target.getSocketedItem = source.GetSocketedItem
      target.getSocketedRelic = source.GetSocketedRelic
      target.getSpellBookItem = source.GetSpellBookItem
      target.getSpellByID = source.GetSpellByID
      target.getTalent = source.GetTalent
      target.getTotem = source.GetTotem
      target.getToyByItemID = source.GetToyByItemID
      target.getTradePlayerItem = source.GetTradePlayerItem
      target.getTradeTargetItem = source.GetTradeTargetItem
      target.getTrainerService = source.GetTrainerService
      target.getTraitEntry = source.GetTraitEntry
      target.getUnit = source.GetUnit
      target.getUnitAura = source.GetUnitAura
      target.getUnitAuraByAuraInstanceID = source.GetUnitAuraByAuraInstanceID
      target.getUnitBuff = source.GetUnitBuff
      target.getUnitBuffByAuraInstanceID = source.GetUnitBuffByAuraInstanceID
      target.getUnitDebuff = source.GetUnitDebuff
      target.getUnitDebuffByAuraInstanceID = source.GetUnitDebuffByAuraInstanceID
      target.getUpgradeItem = source.GetUpgradeItem
      target.getWeeklyReward = source.GetWeeklyReward
      target.getWorldCursor = source.GetWorldCursor
      target.getWorldLootObject = source.GetWorldLootObject
    end
  end
  do
    local target = {}
    api.totem = target
    target.destroyTotem = host.DestroyTotem
    target.getNumTotemSlots = host.GetNumTotemSlots
    target.getTotemCannotDismiss = host.GetTotemCannotDismiss
    target.getTotemDuration = host.GetTotemDuration
    target.getTotemInfo = host.GetTotemInfo
    target.getTotemTimeLeft = host.GetTotemTimeLeft
    target.targetTotem = host.TargetTotem
  end
  do
    local source = host.C_ToyBoxInfo
    if source then
      local target = {}
      api.toyBoxInfo = target
      target.clearFanfare = source.ClearFanfare
      target.isToySourceValid = source.IsToySourceValid
      target.isUsingDefaultFilters = source.IsUsingDefaultFilters
      target.needsFanfare = source.NeedsFanfare
      target.setDefaultFilters = source.SetDefaultFilters
    end
  end
  do
    local source = host.C_TradeInfo
    if source then
      local target = {}
      api.tradeInfo = target
      target.addTradeMoney = source.AddTradeMoney
      target.pickupTradeMoney = source.PickupTradeMoney
      target.setTradeMoney = source.SetTradeMoney
      target.shouldShowTradeOfferWarning = source.ShouldShowTradeOfferWarning
    end
  end
  do
    local source = host.C_TradeSkillUI
    if source then
      local target = {}
      api.tradeSkillUI = target
      target.canStoreEnchantInItem = source.CanStoreEnchantInItem
      target.cancelProfessionRespec = source.CancelProfessionRespec
      target.checkRespecNPC = source.CheckRespecNPC
      target.closeTradeSkill = source.CloseTradeSkill
      target.confirmProfessionRespec = source.ConfirmProfessionRespec
      target.craftEnchant = source.CraftEnchant
      target.craftRecipe = source.CraftRecipe
      target.craftSalvage = source.CraftSalvage
      target.doesRecraftingRecipeAcceptItem = source.DoesRecraftingRecipeAcceptItem
      target.getAllProfessionTradeSkillLines = source.GetAllProfessionTradeSkillLines
      target.getBaseProfessionInfo = source.GetBaseProfessionInfo
      target.getChildProfessionInfo = source.GetChildProfessionInfo
      target.getChildProfessionInfos = source.GetChildProfessionInfos
      target.getConcentrationCurrencyID = source.GetConcentrationCurrencyID
      target.getCraftableCount = source.GetCraftableCount
      target.getCraftingOperationInfo = source.GetCraftingOperationInfo
      target.getCraftingOperationInfoForOrder = source.GetCraftingOperationInfoForOrder
      target.getCraftingReagentBonusText = source.GetCraftingReagentBonusText
      target.getCraftingTargetItems = source.GetCraftingTargetItems
      target.getDependentReagents = source.GetDependentReagents
      target.getEnchantItems = source.GetEnchantItems
      target.getFactionSpecificOutputItem = source.GetFactionSpecificOutputItem
      target.getGatheringOperationInfo = source.GetGatheringOperationInfo
      target.getHideUnownedFlags = source.GetHideUnownedFlags
      target.getItemCraftedQualityByItemInfo = source.GetItemCraftedQualityByItemInfo
      target.getItemCraftedQualityInfo = source.GetItemCraftedQualityInfo
      target.getItemReagentQualityByItemInfo = source.GetItemReagentQualityByItemInfo
      target.getItemReagentQualityInfo = source.GetItemReagentQualityInfo
      target.getItemSlotModifications = source.GetItemSlotModifications
      target.getItemSlotModificationsForOrder = source.GetItemSlotModificationsForOrder
      target.getOriginalCraftRecipeID = source.GetOriginalCraftRecipeID
      target.getProfessionByInventorySlot = source.GetProfessionByInventorySlot
      target.getProfessionChildSkillLineID = source.GetProfessionChildSkillLineID
      target.getProfessionForCursorItem = source.GetProfessionForCursorItem
      target.getProfessionInfoByRecipeID = source.GetProfessionInfoByRecipeID
      target.getProfessionInfoBySkillLineID = source.GetProfessionInfoBySkillLineID
      target.getProfessionInventorySlots = source.GetProfessionInventorySlots
      target.getProfessionNameForSkillLineAbility = source.GetProfessionNameForSkillLineAbility
      target.getProfessionSkillLineID = source.GetProfessionSkillLineID
      target.getProfessionSlots = source.GetProfessionSlots
      target.getProfessionSpells = source.GetProfessionSpells
      target.getQualitiesForRecipe = source.GetQualitiesForRecipe
      target.getReagentDifficultyText = source.GetReagentDifficultyText
      target.getReagentSlotStatus = source.GetReagentSlotStatus
      target.getRecipeDescription = source.GetRecipeDescription
      target.getRecipeInfo = source.GetRecipeInfo
      target.getRecipeInfoForSkillLineAbility = source.GetRecipeInfoForSkillLineAbility
      target.getRecipeItemQualityInfo = source.GetRecipeItemQualityInfo
      target.getRecipeOutputItemData = source.GetRecipeOutputItemData
      target.getRecipeQualityItemIDs = source.GetRecipeQualityItemIDs
      target.getRecipeQualityReagentLink = source.GetRecipeQualityReagentLink
      target.getRecipeRequirements = source.GetRecipeRequirements
      target.getRecipeSchematic = source.GetRecipeSchematic
      target.getRecipesTracked = source.GetRecipesTracked
      target.getRecraftItems = source.GetRecraftItems
      target.getRecraftRemovalWarnings = source.GetRecraftRemovalWarnings
      target.getRemainingRecasts = source.GetRemainingRecasts
      target.getSalvagableItemIDs = source.GetSalvagableItemIDs
      target.getShowLearned = source.GetShowLearned
      target.getShowUnlearned = source.GetShowUnlearned
      target.getSkillLineForGear = source.GetSkillLineForGear
      target.getSourceTypeFilter = source.GetSourceTypeFilter
      target.getTradeSkillDisplayName = source.GetTradeSkillDisplayName
      target.hasFavoriteOrderRecipes = source.HasFavoriteOrderRecipes
      target.isEnchantTargetValid = source.IsEnchantTargetValid
      target.isGuildTradeSkillsEnabled = source.IsGuildTradeSkillsEnabled
      target.isNPCCrafting = source.IsNPCCrafting
      target.isNearProfessionSpellFocus = source.IsNearProfessionSpellFocus
      target.isOriginalCraftRecipeLearned = source.IsOriginalCraftRecipeLearned
      target.isRecipeFirstCraft = source.IsRecipeFirstCraft
      target.isRecipeInBaseSkillLine = source.IsRecipeInBaseSkillLine
      target.isRecipeInSkillLine = source.IsRecipeInSkillLine
      target.isRecipeProfessionLearned = source.IsRecipeProfessionLearned
      target.isRecipeTracked = source.IsRecipeTracked
      target.isRecraftItemEquipped = source.IsRecraftItemEquipped
      target.isRecraftReagentValid = source.IsRecraftReagentValid
      target.isRuneforging = source.IsRuneforging
      target.openRecipe = source.OpenRecipe
      target.openTradeSkill = source.OpenTradeSkill
      target.recraftLimitCategoryValid = source.RecraftLimitCategoryValid
      target.recraftRecipe = source.RecraftRecipe
      target.recraftRecipeForOrder = source.RecraftRecipeForOrder
      target.setOnlyShowAvailableForOrders = source.SetOnlyShowAvailableForOrders
      target.setProfessionChildSkillLineID = source.SetProfessionChildSkillLineID
      target.setRecipeTracked = source.SetRecipeTracked
      target.setShowLearned = source.SetShowLearned
      target.setShowUnlearned = source.SetShowUnlearned
      target.setSourceTypeFilter = source.SetSourceTypeFilter
    end
  end
  do
    local source = host.C_Trainer
    if source then
      local target = {}
      api.trainer = target
    end
  end
  do
    local source = host.C_TraitConfig
    if source then
      local target = {}
      api.traitConfig = target
    end
  end
  do
    local source = host.C_Traits
    if source then
      local target = {}
      api.traits = target
      target.canEditConfig = source.CanEditConfig
      target.canPurchaseRank = source.CanPurchaseRank
      target.canRefundRank = source.CanRefundRank
      target.cascadeRepurchaseRanks = source.CascadeRepurchaseRanks
      target.clearCascadeRepurchaseHistory = source.ClearCascadeRepurchaseHistory
      target.closeTraitSystemInteraction = source.CloseTraitSystemInteraction
      target.commitConfig = source.CommitConfig
      target.configHasStagedChanges = source.ConfigHasStagedChanges
      target.generateImportString = source.GenerateImportString
      target.generateInspectImportString = source.GenerateInspectImportString
      target.getConditionInfo = source.GetConditionInfo
      target.getConfigIDBySystemID = source.GetConfigIDBySystemID
      target.getConfigIDByTreeID = source.GetConfigIDByTreeID
      target.getConfigInfo = source.GetConfigInfo
      target.getConfigVariationID = source.GetConfigVariationID
      target.getConfigsByType = source.GetConfigsByType
      target.getDefinitionInfo = source.GetDefinitionInfo
      target.getEntryInfo = source.GetEntryInfo
      target.getIncreasedTraitData = source.GetIncreasedTraitData
      target.getLoadoutSerializationVersion = source.GetLoadoutSerializationVersion
      target.getNodeCost = source.GetNodeCost
      target.getNodeInfo = source.GetNodeInfo
      target.getStagedChanges = source.GetStagedChanges
      target.getStagedChangesCost = source.GetStagedChangesCost
      target.getSubTreeInfo = source.GetSubTreeInfo
      target.getSystemIDByTreeID = source.GetSystemIDByTreeID
      target.getTraitCurrencyInfo = source.GetTraitCurrencyInfo
      target.getTraitDescription = source.GetTraitDescription
      target.getTraitSystemFlags = source.GetTraitSystemFlags
      target.getTraitSystemWidgetSetID = source.GetTraitSystemWidgetSetID
      target.getTreeCurrencyInfo = source.GetTreeCurrencyInfo
      target.getTreeHash = source.GetTreeHash
      target.getTreeInfo = source.GetTreeInfo
      target.getTreeNodes = source.GetTreeNodes
      target.hasValidInspectData = source.HasValidInspectData
      target.isReadyForCommit = source.IsReadyForCommit
      target.purchaseAllRanks = source.PurchaseAllRanks
      target.purchaseRank = source.PurchaseRank
      target.refundAllRanks = source.RefundAllRanks
      target.refundRank = source.RefundRank
      target.resetTree = source.ResetTree
      target.resetTreeByCurrency = source.ResetTreeByCurrency
      target.rollbackConfig = source.RollbackConfig
      target.setSelection = source.SetSelection
      target.stageConfig = source.StageConfig
      target.talentTestUnlearnSpells = source.TalentTestUnlearnSpells
      target.tryPurchaseAllRanks = source.TryPurchaseAllRanks
      target.tryPurchaseToNode = source.TryPurchaseToNode
      target.tryRefundToNode = source.TryRefundToNode
    end
  end
  do
    local source = host.C_Transmog
    if source then
      local target = {}
      api.transmog = target
      target.canHaveSecondaryAppearanceForSlotID = source.CanHaveSecondaryAppearanceForSlotID
      target.extractTransmogIDList = source.ExtractTransmogIDList
      target.getAllSetAppearancesByID = source.GetAllSetAppearancesByID
      target.getItemIDForSource = source.GetItemIDForSource
      target.getSlotForInventoryType = source.GetSlotForInventoryType
      target.getSlotVisualInfo = source.GetSlotVisualInfo
      target.isAtTransmogNPC = source.IsAtTransmogNPC
    end
  end
  do
    local source = host.C_TransmogCollection
    if source then
      local target = {}
      api.transmogCollection = target
      target.accountCanCollectSource = source.AccountCanCollectSource
      target.areAllCollectionTypeFiltersChecked = source.AreAllCollectionTypeFiltersChecked
      target.areAllSourceTypeFiltersChecked = source.AreAllSourceTypeFiltersChecked
      target.canAppearanceHaveIllusion = source.CanAppearanceHaveIllusion
      target.clearNewAppearance = source.ClearNewAppearance
      target.clearSearch = source.ClearSearch
      target.deleteCustomSet = source.DeleteCustomSet
      target.endSearch = source.EndSearch
      target.getAllAppearanceSources = source.GetAllAppearanceSources
      target.getAllFactionsShown = source.GetAllFactionsShown
      target.getAllRacesShown = source.GetAllRacesShown
      target.getAppearanceCameraID = source.GetAppearanceCameraID
      target.getAppearanceCameraIDBySource = source.GetAppearanceCameraIDBySource
      target.getAppearanceInfoBySource = source.GetAppearanceInfoBySource
      target.getAppearanceSourceDrops = source.GetAppearanceSourceDrops
      target.getAppearanceSourceInfo = source.GetAppearanceSourceInfo
      target.getAppearanceSources = source.GetAppearanceSources
      target.getArtifactAppearanceStrings = source.GetArtifactAppearanceStrings
      target.getCategoryAppearances = source.GetCategoryAppearances
      target.getCategoryCollectedCount = source.GetCategoryCollectedCount
      target.getCategoryForItem = source.GetCategoryForItem
      target.getCategoryInfo = source.GetCategoryInfo
      target.getCategoryTotal = source.GetCategoryTotal
      target.getClassFilter = source.GetClassFilter
      target.getCollectedShown = source.GetCollectedShown
      target.getCustomSetHyperlinkFromItemTransmogInfoList =
        source.GetCustomSetHyperlinkFromItemTransmogInfoList
      target.getCustomSetInfo = source.GetCustomSetInfo
      target.getCustomSetItemTransmogInfoList = source.GetCustomSetItemTransmogInfoList
      target.getCustomSets = source.GetCustomSets
      target.getFallbackWeaponAppearance = source.GetFallbackWeaponAppearance
      target.getFilteredCategoryCollectedCount = source.GetFilteredCategoryCollectedCount
      target.getFilteredCategoryTotal = source.GetFilteredCategoryTotal
      target.getIllusionInfo = source.GetIllusionInfo
      target.getIllusionStrings = source.GetIllusionStrings
      target.getIllusions = source.GetIllusions
      target.getInspectItemTransmogInfoList = source.GetInspectItemTransmogInfoList
      target.getIsAppearanceFavorite = source.GetIsAppearanceFavorite
      target.getItemInfo = source.GetItemInfo
      target.getItemTransmogInfoListFromCustomSetHyperlink =
        source.GetItemTransmogInfoListFromCustomSetHyperlink
      target.getLatestAppearance = source.GetLatestAppearance
      target.getNumMaxCustomSets = source.GetNumMaxCustomSets
      target.getNumTransmogSources = source.GetNumTransmogSources
      target.getPairedArtifactAppearance = source.GetPairedArtifactAppearance
      target.getSourceIcon = source.GetSourceIcon
      target.getSourceInfo = source.GetSourceInfo
      target.getSourceItemID = source.GetSourceItemID
      target.getSourceRequiredHoliday = source.GetSourceRequiredHoliday
      target.getUncollectedShown = source.GetUncollectedShown
      target.getValidAppearanceSourcesForClass = source.GetValidAppearanceSourcesForClass
      target.hasFavorites = source.HasFavorites
      target.isAppearanceHiddenVisual = source.IsAppearanceHiddenVisual
      target.isCategoryValidForItem = source.IsCategoryValidForItem
      target.isNewAppearance = source.IsNewAppearance
      target.isSearchDBLoading = source.IsSearchDBLoading
      target.isSearchInProgress = source.IsSearchInProgress
      target.isSourceTypeFilterChecked = source.IsSourceTypeFilterChecked
      target.isSpellItemEnchantmentHiddenVisual = source.IsSpellItemEnchantmentHiddenVisual
      target.isUsingDefaultFilters = source.IsUsingDefaultFilters
      target.isValidCustomSetName = source.IsValidCustomSetName
      target.isValidTransmogSource = source.IsValidTransmogSource
      target.modifyCustomSet = source.ModifyCustomSet
      target.newCustomSet = source.NewCustomSet
      target.playerCanCollectSource = source.PlayerCanCollectSource
      target.playerHasTransmog = source.PlayerHasTransmog
      target.playerHasTransmogByItemInfo = source.PlayerHasTransmogByItemInfo
      target.playerHasTransmogItemModifiedAppearance =
        source.PlayerHasTransmogItemModifiedAppearance
      target.playerKnowsSource = source.PlayerKnowsSource
      target.renameCustomSet = source.RenameCustomSet
      target.searchProgress = source.SearchProgress
      target.searchSize = source.SearchSize
      target.setAllCollectionTypeFilters = source.SetAllCollectionTypeFilters
      target.setAllFactionsShown = source.SetAllFactionsShown
      target.setAllRacesShown = source.SetAllRacesShown
      target.setAllSourceTypeFilters = source.SetAllSourceTypeFilters
      target.setClassFilter = source.SetClassFilter
      target.setCollectedShown = source.SetCollectedShown
      target.setDefaultFilters = source.SetDefaultFilters
      target.setIsAppearanceFavorite = source.SetIsAppearanceFavorite
      target.setSearch = source.SetSearch
      target.setSearchAndFilterCategory = source.SetSearchAndFilterCategory
      target.setSourceTypeFilter = source.SetSourceTypeFilter
      target.setUncollectedShown = source.SetUncollectedShown
      target.updateUsableAppearances = source.UpdateUsableAppearances
    end
  end
  do
    local source = host.C_TransmogOutfitInfo
    if source then
      local target = {}
      api.transmogOutfitInfo = target
      target.addNewOutfit = source.AddNewOutfit
      target.canPlayerTransmogSlot = source.CanPlayerTransmogSlot
      target.changeDisplayedOutfit = source.ChangeDisplayedOutfit
      target.changeToOutfit = source.ChangeToOutfit
      target.changeViewedOutfit = source.ChangeViewedOutfit
      target.clearAllPendingSituations = source.ClearAllPendingSituations
      target.clearAllPendingTransmogs = source.ClearAllPendingTransmogs
      target.clearDisplayedOutfit = source.ClearDisplayedOutfit
      target.clearOutfit = source.ClearOutfit
      target.commitAndApplyAllPending = source.CommitAndApplyAllPending
      target.commitOutfitInfo = source.CommitOutfitInfo
      target.commitPendingSituations = source.CommitPendingSituations
      target.getActiveOutfitID = source.GetActiveOutfitID
      target.getAllSlotLocationInfo = source.GetAllSlotLocationInfo
      target.getAllTransmogOutfitOptionSheatheCategoryInfo =
        source.GetAllTransmogOutfitOptionSheatheCategoryInfo
      target.getCollectionInfoForSlotAndOption = source.GetCollectionInfoForSlotAndOption
      target.getCurrentlyViewedOutfitID = source.GetCurrentlyViewedOutfitID
      target.getEquippedSlotOptionFromTransmogSlot = source.GetEquippedSlotOptionFromTransmogSlot
      target.getIllusionDefaultIMAIDForCollectionType =
        source.GetIllusionDefaultIMAIDForCollectionType
      target.getItemModifiedAppearanceEffectiveCategory =
        source.GetItemModifiedAppearanceEffectiveCategory
      target.getLinkedSlotInfo = source.GetLinkedSlotInfo
      target.getMaxNumberOfTotalOutfitsForSource = source.GetMaxNumberOfTotalOutfitsForSource
      target.getMaxNumberOfUsableOutfits = source.GetMaxNumberOfUsableOutfits
      target.getNextOutfitCost = source.GetNextOutfitCost
      target.getNumberOfOutfitsUnlockedForSource = source.GetNumberOfOutfitsUnlockedForSource
      target.getOutfitInfo = source.GetOutfitInfo
      target.getOutfitInfoByName = source.GetOutfitInfoByName
      target.getOutfitInfoByPlayerFacingIndex = source.GetOutfitInfoByPlayerFacingIndex
      target.getOutfitSituation = source.GetOutfitSituation
      target.getOutfitSituationsEnabled = source.GetOutfitSituationsEnabled
      target.getOutfitsInfo = source.GetOutfitsInfo
      target.getPendingTransmogCost = source.GetPendingTransmogCost
      target.getSecondarySlotState = source.GetSecondarySlotState
      target.getSetSourcesForSlot = source.GetSetSourcesForSlot
      target.getSlotGroupInfo = source.GetSlotGroupInfo
      target.getSourceIDsForSlot = source.GetSourceIDsForSlot
      target.getTransmogOutfitSlotForInventoryType = source.GetTransmogOutfitSlotForInventoryType
      target.getTransmogOutfitSlotFromInventorySlot = source.GetTransmogOutfitSlotFromInventorySlot
      target.getUISituationCategoriesAndOptions = source.GetUISituationCategoriesAndOptions
      target.getUnassignedAtlasForSlot = source.GetUnassignedAtlasForSlot
      target.getUnassignedDisplayAtlasForSlot = source.GetUnassignedDisplayAtlasForSlot
      target.getViewedOutfitSlotInfo = source.GetViewedOutfitSlotInfo
      target.getWeaponOptionsForSlot = source.GetWeaponOptionsForSlot
      target.hasPendingOutfitSituations = source.HasPendingOutfitSituations
      target.hasPendingOutfitTransmogs = source.HasPendingOutfitTransmogs
      target.inTransmogEvent = source.InTransmogEvent
      target.isEquippedGearOutfitDisplayed = source.IsEquippedGearOutfitDisplayed
      target.isEquippedGearOutfitLocked = source.IsEquippedGearOutfitLocked
      target.isLockedOutfit = source.IsLockedOutfit
      target.isSlotWeaponSlot = source.IsSlotWeaponSlot
      target.isTransmogEnabled = source.IsTransmogEnabled
      target.isUsableDiscountAvailable = source.IsUsableDiscountAvailable
      target.isValidTransmogOutfitName = source.IsValidTransmogOutfitName
      target.pickupOutfit = source.PickupOutfit
      target.resetOutfitSituations = source.ResetOutfitSituations
      target.revertPendingTransmog = source.RevertPendingTransmog
      target.setOutfitSituationsEnabled = source.SetOutfitSituationsEnabled
      target.setOutfitToCustomSet = source.SetOutfitToCustomSet
      target.setOutfitToOutfit = source.SetOutfitToOutfit
      target.setOutfitToSet = source.SetOutfitToSet
      target.setPendingTransmog = source.SetPendingTransmog
      target.setPendingTransmogSheatheCategory = source.SetPendingTransmogSheatheCategory
      target.setSecondarySlotState = source.SetSecondarySlotState
      target.setViewedWeaponOptionForSlot = source.SetViewedWeaponOptionForSlot
      target.slotHasSecondary = source.SlotHasSecondary
      target.transmogEventActive = source.TransmogEventActive
      target.updatePendingSituation = source.UpdatePendingSituation
    end
  end
  do
    local source = host.C_TransmogSets
    if source then
      local target = {}
      api.transmogSets = target
      target.clearLatestSource = source.ClearLatestSource
      target.clearNewSource = source.ClearNewSource
      target.clearSetNewSourcesForSlot = source.ClearSetNewSourcesForSlot
      target.getAllSets = source.GetAllSets
      target.getAllSourceIDs = source.GetAllSourceIDs
      target.getAvailableSets = source.GetAvailableSets
      target.getBaseSetID = source.GetBaseSetID
      target.getBaseSets = source.GetBaseSets
      target.getBaseSetsFilter = source.GetBaseSetsFilter
      target.getCameraIDs = source.GetCameraIDs
      target.getFilteredBaseSetsCounts = source.GetFilteredBaseSetsCounts
      target.getFullBaseSetsCounts = source.GetFullBaseSetsCounts
      target.getIsFavorite = source.GetIsFavorite
      target.getLatestSource = source.GetLatestSource
      target.getSetInfo = source.GetSetInfo
      target.getSetNewSources = source.GetSetNewSources
      target.getSetPrimaryAppearances = source.GetSetPrimaryAppearances
      target.getSetsContainingSourceID = source.GetSetsContainingSourceID
      target.getSetsFilter = source.GetSetsFilter
      target.getSourceIDsForSlot = source.GetSourceIDsForSlot
      target.getSourcesForSlot = source.GetSourcesForSlot
      target.getTransmogSetsClassFilter = source.GetTransmogSetsClassFilter
      target.getUsableSets = source.GetUsableSets
      target.getValidBaseSetsCountsForCharacter = source.GetValidBaseSetsCountsForCharacter
      target.getValidClassForSet = source.GetValidClassForSet
      target.getVariantSets = source.GetVariantSets
      target.hasAvailableSets = source.HasAvailableSets
      target.hasUsableSets = source.HasUsableSets
      target.isBaseSetCollected = source.IsBaseSetCollected
      target.isNewSource = source.IsNewSource
      target.isSetVisible = source.IsSetVisible
      target.isUsingDefaultBaseSetsFilters = source.IsUsingDefaultBaseSetsFilters
      target.isUsingDefaultSetsFilters = source.IsUsingDefaultSetsFilters
      target.setBaseSetsFilter = source.SetBaseSetsFilter
      target.setDefaultBaseSetsFilters = source.SetDefaultBaseSetsFilters
      target.setDefaultSetsFilters = source.SetDefaultSetsFilters
      target.setHasNewSources = source.SetHasNewSources
      target.setHasNewSourcesForSlot = source.SetHasNewSourcesForSlot
      target.setIsFavorite = source.SetIsFavorite
      target.setSetsFilter = source.SetSetsFilter
      target.setTransmogSetsClassFilter = source.SetTransmogSetsClassFilter
    end
  end
  do
    local source = host.C_TTSSettings
    if source then
      local target = {}
      api.ttsSettings = target
      target.getChannelEnabled = source.GetChannelEnabled
      target.getCharacterSettingsSaved = source.GetCharacterSettingsSaved
      target.getChatTypeEnabled = source.GetChatTypeEnabled
      target.getSetting = source.GetSetting
      target.getSpeechRate = source.GetSpeechRate
      target.getSpeechVolume = source.GetSpeechVolume
      target.getVoiceOptionID = source.GetVoiceOptionID
      target.getVoiceOptionName = source.GetVoiceOptionName
      target.markCharacterSettingsSaved = source.MarkCharacterSettingsSaved
      target.setChannelEnabled = source.SetChannelEnabled
      target.setChannelKeyEnabled = source.SetChannelKeyEnabled
      target.setChatTypeEnabled = source.SetChatTypeEnabled
      target.setDefaultSettings = source.SetDefaultSettings
      target.setSetting = source.SetSetting
      target.setSpeechRate = source.SetSpeechRate
      target.setSpeechVolume = source.SetSpeechVolume
      target.setVoiceOption = source.SetVoiceOption
      target.setVoiceOptionName = source.SetVoiceOptionName
      target.shouldOverrideMessage = source.ShouldOverrideMessage
    end
  end
  do
    local source = host.C_Tutorial
    if source then
      local target = {}
      api.tutorial = target
      target.abandonTutorialArea = source.AbandonTutorialArea
      target.getCombatEventInfo = source.GetCombatEventInfo
      target.returnToTutorialArea = source.ReturnToTutorialArea
    end
  end
  do
    local source = host.C_UI
    if source then
      local target = {}
      api.ui = target
      target.doesAnyDisplayHaveNotch = source.DoesAnyDisplayHaveNotch
      target.getTopLeftNotchSafeRegion = source.GetTopLeftNotchSafeRegion
      target.getTopRightNotchSafeRegion = source.GetTopRightNotchSafeRegion
      target.getUIParent = source.GetUIParent
      target.getWorldFrame = source.GetWorldFrame
      target.reload = source.Reload
      target.shouldUIParentAvoidNotch = source.ShouldUIParentAvoidNotch
    end
  end
  do
    local source = host.C_UIActionHandler
    if source then
      local target = {}
      api.uiActionHandler = target
    end
  end
  do
    local source = host.C_UIColor
    if source then
      local target = {}
      api.uiColor = target
      target.getColors = source.GetColors
    end
  end
  do
    local source = host.C_UIFileAsset
    if source then
      local target = {}
      api.uiFileAsset = target
      target.getFileID = source.GetFileID
      target.isKnownFile = source.IsKnownFile
      target.isLooseFile = source.IsLooseFile
    end
  end
  do
    local source = host.C_UIWidgetManager
    if source then
      local target = {}
      api.uiWidgetManager = target
      target.getAllWidgetsBySetID = source.GetAllWidgetsBySetID
      target.getBelowMinimapWidgetSetID = source.GetBelowMinimapWidgetSetID
      target.getBulletTextListWidgetVisualizationInfo =
        source.GetBulletTextListWidgetVisualizationInfo
      target.getButtonHeaderWidgetVisualizationInfo = source.GetButtonHeaderWidgetVisualizationInfo
      target.getCaptureBarWidgetVisualizationInfo = source.GetCaptureBarWidgetVisualizationInfo
      target.getCaptureZoneVisualizationInfo = source.GetCaptureZoneVisualizationInfo
      target.getDiscreteProgressStepsVisualizationInfo =
        source.GetDiscreteProgressStepsVisualizationInfo
      target.getDoubleIconAndTextWidgetVisualizationInfo =
        source.GetDoubleIconAndTextWidgetVisualizationInfo
      target.getDoubleStateIconRowVisualizationInfo = source.GetDoubleStateIconRowVisualizationInfo
      target.getDoubleStatusBarWidgetVisualizationInfo =
        source.GetDoubleStatusBarWidgetVisualizationInfo
      target.getFillUpFramesWidgetVisualizationInfo = source.GetFillUpFramesWidgetVisualizationInfo
      target.getHorizontalCurrenciesWidgetVisualizationInfo =
        source.GetHorizontalCurrenciesWidgetVisualizationInfo
      target.getIconAndTextWidgetVisualizationInfo = source.GetIconAndTextWidgetVisualizationInfo
      target.getIconTextAndBackgroundWidgetVisualizationInfo =
        source.GetIconTextAndBackgroundWidgetVisualizationInfo
      target.getIconTextAndCurrenciesWidgetVisualizationInfo =
        source.GetIconTextAndCurrenciesWidgetVisualizationInfo
      target.getItemDisplayVisualizationInfo = source.GetItemDisplayVisualizationInfo
      target.getMapPinAnimationWidgetVisualizationInfo =
        source.GetMapPinAnimationWidgetVisualizationInfo
      target.getObjectiveTrackerWidgetSetID = source.GetObjectiveTrackerWidgetSetID
      target.getPowerBarWidgetSetID = source.GetPowerBarWidgetSetID
      target.getPreyHuntProgressWidgetVisualizationInfo =
        source.GetPreyHuntProgressWidgetVisualizationInfo
      target.getScenarioHeaderCurrenciesAndBackgroundWidgetVisualizationInfo =
        source.GetScenarioHeaderCurrenciesAndBackgroundWidgetVisualizationInfo
      target.getScenarioHeaderDelvesWidgetVisualizationInfo =
        source.GetScenarioHeaderDelvesWidgetVisualizationInfo
      target.getScenarioHeaderTimerWidgetVisualizationInfo =
        source.GetScenarioHeaderTimerWidgetVisualizationInfo
      target.getSpacerVisualizationInfo = source.GetSpacerVisualizationInfo
      target.getSpellDisplayVisualizationInfo = source.GetSpellDisplayVisualizationInfo
      target.getStackedResourceTrackerWidgetVisualizationInfo =
        source.GetStackedResourceTrackerWidgetVisualizationInfo
      target.getStatusBarWidgetVisualizationInfo = source.GetStatusBarWidgetVisualizationInfo
      target.getTextColumnRowVisualizationInfo = source.GetTextColumnRowVisualizationInfo
      target.getTextWithStateWidgetVisualizationInfo =
        source.GetTextWithStateWidgetVisualizationInfo
      target.getTextWithSubtextWidgetVisualizationInfo =
        source.GetTextWithSubtextWidgetVisualizationInfo
      target.getTextureAndTextRowVisualizationInfo = source.GetTextureAndTextRowVisualizationInfo
      target.getTextureAndTextVisualizationInfo = source.GetTextureAndTextVisualizationInfo
      target.getTextureWithAnimationVisualizationInfo =
        source.GetTextureWithAnimationVisualizationInfo
      target.getTopCenterWidgetSetID = source.GetTopCenterWidgetSetID
      target.getTugOfWarWidgetVisualizationInfo = source.GetTugOfWarWidgetVisualizationInfo
      target.getUnitPowerBarWidgetVisualizationInfo = source.GetUnitPowerBarWidgetVisualizationInfo
      target.getWidgetSetInfo = source.GetWidgetSetInfo
      target.getZoneControlVisualizationInfo = source.GetZoneControlVisualizationInfo
      target.registerUnitForWidgetUpdates = source.RegisterUnitForWidgetUpdates
      target.setProcessingUnit = source.SetProcessingUnit
      target.setProcessingUnitGuid = source.SetProcessingUnitGuid
      target.unregisterUnitForWidgetUpdates = source.UnregisterUnitForWidgetUpdates
    end
  end
  do
    local target = {}
    api.unit = target
    target.canEjectPassengerFromSeat = host.CanEjectPassengerFromSeat
    target.canSwitchVehicleSeat = host.CanSwitchVehicleSeat
    target.closestGameObjectPosition = host.ClosestGameObjectPosition
    target.closestUnitPosition = host.ClosestUnitPosition
    target.createUnitHealPredictionCalculator = host.CreateUnitHealPredictionCalculator
    target.ejectPassengerFromSeat = host.EjectPassengerFromSeat
    target.getComboPoints = host.GetComboPoints
    target.getNegativeCorruptionEffectInfo = host.GetNegativeCorruptionEffectInfo
    target.getUnitChargedPowerPoints = host.GetUnitChargedPowerPoints
    target.getUnitEmpowerHoldAtMaxTime = host.GetUnitEmpowerHoldAtMaxTime
    target.getUnitEmpowerMinHoldTime = host.GetUnitEmpowerMinHoldTime
    target.getUnitEmpowerStageDuration = host.GetUnitEmpowerStageDuration
    target.getUnitHealthModifier = host.GetUnitHealthModifier
    target.getUnitMaxHealthModifier = host.GetUnitMaxHealthModifier
    target.getUnitPowerBarInfo = host.GetUnitPowerBarInfo
    target.getUnitPowerBarInfoByID = host.GetUnitPowerBarInfoByID
    target.getUnitPowerBarStrings = host.GetUnitPowerBarStrings
    target.getUnitPowerBarStringsByID = host.GetUnitPowerBarStringsByID
    target.getUnitPowerBarTextureInfo = host.GetUnitPowerBarTextureInfo
    target.getUnitPowerBarTextureInfoByID = host.GetUnitPowerBarTextureInfoByID
    target.getUnitPowerModifier = host.GetUnitPowerModifier
    target.getUnitSpeed = host.GetUnitSpeed
    target.getUnitTotalModifiedMaxHealthPercent = host.GetUnitTotalModifiedMaxHealthPercent
    target.getVehicleUIIndicator = host.GetVehicleUIIndicator
    target.getVehicleUIIndicatorSeat = host.GetVehicleUIIndicatorSeat
    target.isFalling = host.IsFalling
    target.isFlying = host.IsFlying
    target.isPlayerInGuildFromGUID = host.IsPlayerInGuildFromGUID
    target.isSubmerged = host.IsSubmerged
    target.isSwimming = host.IsSwimming
    target.isUnitModelReadyForUI = host.IsUnitModelReadyForUI
    target.playerIsPVPInactive = host.PlayerIsPVPInactive
    target.playerIsSpellTarget = host.PlayerIsSpellTarget
    target.playerVehicleHasComboPoints = host.PlayerVehicleHasComboPoints
    target.reportPlayerIsPVPAFK = host.ReportPlayerIsPVPAFK
    target.resistancePercent = host.ResistancePercent
    target.setPortraitTexture = host.SetPortraitTexture
    target.setPortraitTextureFromCreatureDisplayID = host.SetPortraitTextureFromCreatureDisplayID
    target.setUnitCursorTexture = host.SetUnitCursorTexture
    target.affectingCombat = host.UnitAffectingCombat
    target.alliedRaceInfo = host.UnitAlliedRaceInfo
    target.armor = host.UnitArmor
    target.attackPower = host.UnitAttackPower
    target.attackSpeed = host.UnitAttackSpeed
    target.battlePetLevel = host.UnitBattlePetLevel
    target.battlePetSpeciesID = host.UnitBattlePetSpeciesID
    target.battlePetType = host.UnitBattlePetType
    target.canAssist = host.UnitCanAssist
    target.canAttack = host.UnitCanAttack
    target.canCooperate = host.UnitCanCooperate
    target.canPetBattle = host.UnitCanPetBattle
    target.castingDuration = host.UnitCastingDuration
    target.castingInfo = host.UnitCastingInfo
    target.channelDuration = host.UnitChannelDuration
    target.channelInfo = host.UnitChannelInfo
    target.chromieTimeID = host.UnitChromieTimeID
    target.class = host.UnitClass
    target.classBase = host.UnitClassBase
    target.classFromGUID = host.UnitClassFromGUID
    target.classification = host.UnitClassification
    target.controllingVehicle = host.UnitControllingVehicle
    target.creatureFamily = host.UnitCreatureFamily
    target.creatureID = host.UnitCreatureID
    target.creatureType = host.UnitCreatureType
    target.damage = host.UnitDamage
    target.detailedThreatSituation = host.UnitDetailedThreatSituation
    target.distanceSquared = host.UnitDistanceSquared
    target.effectiveLevel = host.UnitEffectiveLevel
    target.empoweredChannelDuration = host.UnitEmpoweredChannelDuration
    target.empoweredStageDurations = host.UnitEmpoweredStageDurations
    target.empoweredStagePercentages = host.UnitEmpoweredStagePercentages
    target.exists = host.UnitExists
    target.factionGroup = host.UnitFactionGroup
    target.fullName = host.UnitFullName
    target.guid = host.UnitGUID
    target.getDetailedHealPrediction = host.UnitGetDetailedHealPrediction
    target.getIncomingHeals = host.UnitGetIncomingHeals
    target.getTotalAbsorbs = host.UnitGetTotalAbsorbs
    target.getTotalHealAbsorbs = host.UnitGetTotalHealAbsorbs
    target.groupRolesAssigned = host.UnitGroupRolesAssigned
    target.groupRolesAssignedEnum = host.UnitGroupRolesAssignedEnum
    target.hpPerStamina = host.UnitHPPerStamina
    target.hasPowerType = host.UnitHasPowerType
    target.hasRelicSlot = host.UnitHasRelicSlot
    target.hasVehiclePlayerFrameUI = host.UnitHasVehiclePlayerFrameUI
    target.hasVehicleUI = host.UnitHasVehicleUI
    target.health = host.UnitHealth
    target.healthMax = host.UnitHealthMax
    target.healthMissing = host.UnitHealthMissing
    target.healthPercent = host.UnitHealthPercent
    target.honor = host.UnitHonor
    target.honorLevel = host.UnitHonorLevel
    target.honorMax = host.UnitHonorMax
    target.inAnyGroup = host.UnitInAnyGroup
    target.inBattleground = host.UnitInBattleground
    target.inOtherParty = host.UnitInOtherParty
    target.inParty = host.UnitInParty
    target.inPartyIsAI = host.UnitInPartyIsAI
    target.inPartyShard = host.UnitInPartyShard
    target.inRaid = host.UnitInRaid
    target.inRange = host.UnitInRange
    target.inSubgroup = host.UnitInSubgroup
    target.inVehicle = host.UnitInVehicle
    target.inVehicleControlSeat = host.UnitInVehicleControlSeat
    target.inVehicleHidesPetFrame = host.UnitInVehicleHidesPetFrame
    target.isAFK = host.UnitIsAFK
    target.isBattlePet = host.UnitIsBattlePet
    target.isBattlePetCompanion = host.UnitIsBattlePetCompanion
    target.isBossMob = host.UnitIsBossMob
    target.isCharmed = host.UnitIsCharmed
    target.isConnected = host.UnitIsConnected
    target.isControlling = host.UnitIsControlling
    target.isCorpse = host.UnitIsCorpse
    target.isDND = host.UnitIsDND
    target.isDead = host.UnitIsDead
    target.isDeadOrGhost = host.UnitIsDeadOrGhost
    target.isEnemy = host.UnitIsEnemy
    target.isFeignDeath = host.UnitIsFeignDeath
    target.isFriend = host.UnitIsFriend
    target.isGameObject = host.UnitIsGameObject
    target.isGhost = host.UnitIsGhost
    target.isGroupAssistant = host.UnitIsGroupAssistant
    target.isGroupLeader = host.UnitIsGroupLeader
    target.isHumanPlayer = host.UnitIsHumanPlayer
    target.isInMyGuild = host.UnitIsInMyGuild
    target.isInteractable = host.UnitIsInteractable
    target.isLieutenant = host.UnitIsLieutenant
    target.isMercenary = host.UnitIsMercenary
    target.isMinion = host.UnitIsMinion
    target.isNPCAsPlayer = host.UnitIsNPCAsPlayer
    target.isOtherPlayersBattlePet = host.UnitIsOtherPlayersBattlePet
    target.isOtherPlayersPet = host.UnitIsOtherPlayersPet
    target.isOwnerOrControllerOfUnit = host.UnitIsOwnerOrControllerOfUnit
    target.isPVP = host.UnitIsPVP
    target.isPVPFreeForAll = host.UnitIsPVPFreeForAll
    target.isPVPSanctuary = host.UnitIsPVPSanctuary
    target.isPlayer = host.UnitIsPlayer
    target.isPlayerControlledOrGroupMember = host.UnitIsPlayerControlledOrGroupMember
    target.isPossessed = host.UnitIsPossessed
    target.isQuestBoss = host.UnitIsQuestBoss
    target.isRaidOfficer = host.UnitIsRaidOfficer
    target.isSameServer = host.UnitIsSameServer
    target.isTapDenied = host.UnitIsTapDenied
    target.isTrivial = host.UnitIsTrivial
    target.isUnconscious = host.UnitIsUnconscious
    target.isUnit = host.UnitIsUnit
    target.isVisible = host.UnitIsVisible
    target.isWildBattlePet = host.UnitIsWildBattlePet
    target.leadsAnyGroup = host.UnitLeadsAnyGroup
    target.level = host.UnitLevel
    target.name = host.UnitName
    target.nameFromGUID = host.UnitNameFromGUID
    target.nameUnmodified = host.UnitNameUnmodified
    target.nameplateShowsWidgetsOnly = host.UnitNameplateShowsWidgetsOnly
    target.numPowerBarTimers = host.UnitNumPowerBarTimers
    target.onTaxi = host.UnitOnTaxi
    target.ownerGUID = host.UnitOwnerGUID
    target.pvpName = host.UnitPVPName
    target.partialPower = host.UnitPartialPower
    target.percentHealthFromGUID = host.UnitPercentHealthFromGUID
    target.phaseReason = host.UnitPhaseReason
    target.playerControlled = host.UnitPlayerControlled
    target.playerOrPetInParty = host.UnitPlayerOrPetInParty
    target.playerOrPetInRaid = host.UnitPlayerOrPetInRaid
    target.position = host.UnitPosition
    target.power = host.UnitPower
    target.powerBarID = host.UnitPowerBarID
    target.powerBarTimerInfo = host.UnitPowerBarTimerInfo
    target.powerDisplayMod = host.UnitPowerDisplayMod
    target.powerMax = host.UnitPowerMax
    target.powerMissing = host.UnitPowerMissing
    target.powerPercent = host.UnitPowerPercent
    target.powerType = host.UnitPowerType
    target.pvpClassification = host.UnitPvpClassification
    target.questTrivialLevelRange = host.UnitQuestTrivialLevelRange
    target.questTrivialLevelRangeScaling = host.UnitQuestTrivialLevelRangeScaling
    target.race = host.UnitRace
    target.rangedAttackPower = host.UnitRangedAttackPower
    target.rangedDamage = host.UnitRangedDamage
    target.reaction = host.UnitReaction
    target.realmRelationship = host.UnitRealmRelationship
    target.selectionColor = host.UnitSelectionColor
    target.selectionType = host.UnitSelectionType
    target.sex = host.UnitSex
    target.sexBase = host.UnitSexBase
    target.shouldDisplayName = host.UnitShouldDisplayName
    target.shouldDisplaySpellTargetName = host.UnitShouldDisplaySpellTargetName
    target.spellHaste = host.UnitSpellHaste
    target.spellTargetClass = host.UnitSpellTargetClass
    target.spellTargetName = host.UnitSpellTargetName
    target.stagger = host.UnitStagger
    target.stat = host.UnitStat
    target.switchToVehicleSeat = host.UnitSwitchToVehicleSeat
    target.targetsVehicleInRaidUI = host.UnitTargetsVehicleInRaidUI
    target.threatLeadSituation = host.UnitThreatLeadSituation
    target.threatPercentageOfLead = host.UnitThreatPercentageOfLead
    target.threatSituation = host.UnitThreatSituation
    target.tokenFromGUID = host.UnitTokenFromGUID
    target.treatAsPlayerForDisplay = host.UnitTreatAsPlayerForDisplay
    target.trialBankedLevels = host.UnitTrialBankedLevels
    target.trialXP = host.UnitTrialXP
    target.usingVehicle = host.UnitUsingVehicle
    target.vehicleSeatCount = host.UnitVehicleSeatCount
    target.vehicleSeatInfo = host.UnitVehicleSeatInfo
    target.vehicleSkin = host.UnitVehicleSkin
    target.weaponAttackPower = host.UnitWeaponAttackPower
    target.widgetSet = host.UnitWidgetSet
    target.xp = host.UnitXP
    target.xpMax = host.UnitXPMax
    target.worldLootObjectExists = host.WorldLootObjectExists
  end
  do
    local source = host.C_UnitAuras
    if source then
      local target = {}
      api.unitAuras = target
      target.addAuraSound = source.AddAuraSound
      target.addBlockedAura = source.AddBlockedAura
      target.addPrivateAuraAnchor = source.AddPrivateAuraAnchor
      target.auraIsBigDefensive = source.AuraIsBigDefensive
      target.auraIsPrivate = source.AuraIsPrivate
      target.cancelAuraByInstanceID = source.CancelAuraByInstanceID
      target.clearBlockedAuras = source.ClearBlockedAuras
      target.doesAuraHaveExpirationTime = source.DoesAuraHaveExpirationTime
      target.getAuraApplicationDisplayCount = source.GetAuraApplicationDisplayCount
      target.getAuraBaseDuration = source.GetAuraBaseDuration
      target.getAuraDataByAuraInstanceID = source.GetAuraDataByAuraInstanceID
      target.getAuraDataByIndex = source.GetAuraDataByIndex
      target.getAuraDataBySlot = source.GetAuraDataBySlot
      target.getAuraDataBySpellName = source.GetAuraDataBySpellName
      target.getAuraDispelTypeColor = source.GetAuraDispelTypeColor
      target.getAuraDuration = source.GetAuraDuration
      target.getAuraSlots = source.GetAuraSlots
      target.getBuffDataByIndex = source.GetBuffDataByIndex
      target.getCooldownAuraBySpellID = source.GetCooldownAuraBySpellID
      target.getDebuffDataByIndex = source.GetDebuffDataByIndex
      target.getGroupBuffVisualAlerts = source.GetGroupBuffVisualAlerts
      target.getHiddenGroupBuffs = source.GetHiddenGroupBuffs
      target.getPlayerAuraBySpellID = source.GetPlayerAuraBySpellID
      target.getRefreshExtendedDuration = source.GetRefreshExtendedDuration
      target.getUnitAuraBySpellID = source.GetUnitAuraBySpellID
      target.getUnitAuraInstanceIDs = source.GetUnitAuraInstanceIDs
      target.getUnitAuras = source.GetUnitAuras
      target.isAuraFilteredOutByInstanceID = source.IsAuraFilteredOutByInstanceID
      target.removeAuraSound = source.RemoveAuraSound
      target.removePrivateAuraAnchor = source.RemovePrivateAuraAnchor
      target.resetAuraDataProvider = source.ResetAuraDataProvider
      target.setGroupBuffVisualAlerts = source.SetGroupBuffVisualAlerts
      target.setHiddenGroupBuffs = source.SetHiddenGroupBuffs
      target.setPrivateWarningTextAnchor = source.SetPrivateWarningTextAnchor
      target.switchAuraDataProvider = source.SwitchAuraDataProvider
      target.wantsAlteredForm = source.WantsAlteredForm
    end
  end
  do
    local target = {}
    api.unitRole = target
    target.areClassRolesSoftSuggestions = host.AreClassRolesSoftSuggestions
    target.canShowSetRoleButton = host.CanShowSetRoleButton
    target.initiateRolePoll = host.InitiateRolePoll
    target.unitGetAvailableRoles = host.UnitGetAvailableRoles
    target.unitSetRole = host.UnitSetRole
    target.unitSetRoleEnum = host.UnitSetRoleEnum
  end
  do
    local target = {}
    api.url = target
    target.launchURL = host.LaunchURL
    target.loadURLIndex = host.LoadURLIndex
  end
  do
    local source = host.C_UserFeedback
    if source then
      local target = {}
      api.userFeedback = target
      target.submitBug = source.SubmitBug
      target.submitSuggestion = source.SubmitSuggestion
    end
  end
  do
    local source = host.C_Vehicle
    if source then
      local target = {}
      api.vehicle = target
    end
  end
  do
    local source = host.C_VideoOptions
    if source then
      local target = {}
      api.videoOptions = target
      target.getCurrentGameWindowSize = source.GetCurrentGameWindowSize
      target.getDefaultGameWindowSize = source.GetDefaultGameWindowSize
      target.getGameWindowSizes = source.GetGameWindowSizes
      target.getGxAdapterInfo = source.GetGxAdapterInfo
      target.isSpellVisualDensitySystemSupported = source.IsSpellVisualDensitySystemSupported
      target.setGameWindowSize = source.SetGameWindowSize
    end
  end
  do
    local source = host.C_VignetteInfo
    if source then
      local target = {}
      api.vignetteInfo = target
      target.findBestUniqueVignette = source.FindBestUniqueVignette
      target.getHealthPercent = source.GetHealthPercent
      target.getRecommendedGroupSize = source.GetRecommendedGroupSize
      target.getVignetteInfo = source.GetVignetteInfo
      target.getVignettePosition = source.GetVignettePosition
      target.getVignettes = source.GetVignettes
    end
  end
  do
    local source = host.C_VoiceChat
    if source then
      local target = {}
      api.voiceChat = target
      target.activateChannel = source.ActivateChannel
      target.activateChannelTranscription = source.ActivateChannelTranscription
      target.beginLocalCapture = source.BeginLocalCapture
      target.canAccessSettings = source.CanAccessSettings
      target.canPlayerUseVoiceChat = source.CanPlayerUseVoiceChat
      target.createChannel = source.CreateChannel
      target.deactivateChannel = source.DeactivateChannel
      target.deactivateChannelTranscription = source.DeactivateChannelTranscription
      target.endLocalCapture = source.EndLocalCapture
      target.getActiveChannelID = source.GetActiveChannelID
      target.getActiveChannelType = source.GetActiveChannelType
      target.getAvailableInputDevices = source.GetAvailableInputDevices
      target.getAvailableOutputDevices = source.GetAvailableOutputDevices
      target.getChannel = source.GetChannel
      target.getChannelForChannelType = source.GetChannelForChannelType
      target.getChannelForCommunityStream = source.GetChannelForCommunityStream
      target.getCommunicationMode = source.GetCommunicationMode
      target.getCurrentVoiceChatConnectionStatusCode =
        source.GetCurrentVoiceChatConnectionStatusCode
      target.getInputVolume = source.GetInputVolume
      target.getJoinClubVoiceChannelError = source.GetJoinClubVoiceChannelError
      target.getLocalPlayerActiveChannelMemberInfo = source.GetLocalPlayerActiveChannelMemberInfo
      target.getLocalPlayerMemberID = source.GetLocalPlayerMemberID
      target.getMasterVolumeScale = source.GetMasterVolumeScale
      target.getMemberGUID = source.GetMemberGUID
      target.getMemberID = source.GetMemberID
      target.getMemberInfo = source.GetMemberInfo
      target.getMemberName = source.GetMemberName
      target.getMemberVolume = source.GetMemberVolume
      target.getOutputVolume = source.GetOutputVolume
      target.getPTTButtonPressedState = source.GetPTTButtonPressedState
      target.getProcesses = source.GetProcesses
      target.getPushToTalkBinding = source.GetPushToTalkBinding
      target.getRemoteTtsVoices = source.GetRemoteTtsVoices
      target.getTtsVoices = source.GetTtsVoices
      target.getVADSensitivity = source.GetVADSensitivity
      target.isChannelJoinPending = source.IsChannelJoinPending
      target.isDeafened = source.IsDeafened
      target.isEnabled = source.IsEnabled
      target.isLoggedIn = source.IsLoggedIn
      target.isMemberLocalPlayer = source.IsMemberLocalPlayer
      target.isMemberMuted = source.IsMemberMuted
      target.isMemberMutedForAll = source.IsMemberMutedForAll
      target.isMemberSilenced = source.IsMemberSilenced
      target.isMuted = source.IsMuted
      target.isParentalDisabled = source.IsParentalDisabled
      target.isParentalMuted = source.IsParentalMuted
      target.isPlayerUsingVoice = source.IsPlayerUsingVoice
      target.isSilenced = source.IsSilenced
      target.isSpeakForMeActive = source.IsSpeakForMeActive
      target.isSpeakForMeAllowed = source.IsSpeakForMeAllowed
      target.isTranscribing = source.IsTranscribing
      target.isTranscriptionAllowed = source.IsTranscriptionAllowed
      target.isVoiceChatConnected = source.IsVoiceChatConnected
      target.leaveChannel = source.LeaveChannel
      target.login = source.Login
      target.logout = source.Logout
      target.markChannelsDiscovered = source.MarkChannelsDiscovered
      target.requestJoinAndActivateCommunityStreamChannel =
        source.RequestJoinAndActivateCommunityStreamChannel
      target.requestJoinChannelByChannelType = source.RequestJoinChannelByChannelType
      target.setCommunicationMode = source.SetCommunicationMode
      target.setDeafened = source.SetDeafened
      target.setInputDevice = source.SetInputDevice
      target.setInputVolume = source.SetInputVolume
      target.setMasterVolumeScale = source.SetMasterVolumeScale
      target.setMemberMuted = source.SetMemberMuted
      target.setMemberVolume = source.SetMemberVolume
      target.setMuted = source.SetMuted
      target.setOutputDevice = source.SetOutputDevice
      target.setOutputVolume = source.SetOutputVolume
      target.setPortraitTexture = source.SetPortraitTexture
      target.setPushToTalkBinding = source.SetPushToTalkBinding
      target.setVADSensitivity = source.SetVADSensitivity
      target.shouldDiscoverChannels = source.ShouldDiscoverChannels
      target.speakRemoteTextSample = source.SpeakRemoteTextSample
      target.speakText = source.SpeakText
      target.stopSpeakingText = source.StopSpeakingText
      target.toggleDeafened = source.ToggleDeafened
      target.toggleMemberMuted = source.ToggleMemberMuted
      target.toggleMuted = source.ToggleMuted
    end
  end
  do
    local source = host.C_WarbandScene
    if source then
      local target = {}
      api.warbandScene = target
      target.getRandomEntryID = source.GetRandomEntryID
      target.getWarbandSceneEntry = source.GetWarbandSceneEntry
      target.hasWarbandScene = source.HasWarbandScene
      target.isFavorite = source.IsFavorite
      target.searchWarbandSceneEntries = source.SearchWarbandSceneEntries
      target.setFavorite = source.SetFavorite
    end
  end
  do
    local source = host.C_WeeklyRewards
    if source then
      local target = {}
      api.weeklyRewards = target
      target.areRewardsForCurrentRewardPeriod = source.AreRewardsForCurrentRewardPeriod
      target.canClaimRewards = source.CanClaimRewards
      target.claimReward = source.ClaimReward
      target.closeInteraction = source.CloseInteraction
      target.getActivities = source.GetActivities
      target.getActivityEncounterInfo = source.GetActivityEncounterInfo
      target.getConquestWeeklyProgress = source.GetConquestWeeklyProgress
      target.getDifficultyIDForActivityTier = source.GetDifficultyIDForActivityTier
      target.getExampleRewardItemHyperlinks = source.GetExampleRewardItemHyperlinks
      target.getItemHyperlink = source.GetItemHyperlink
      target.getNextActivitiesIncrease = source.GetNextActivitiesIncrease
      target.getNextMythicPlusIncrease = source.GetNextMythicPlusIncrease
      target.getNumCompletedDungeonRuns = source.GetNumCompletedDungeonRuns
      target.getSortedProgressForActivity = source.GetSortedProgressForActivity
      target.hasAvailableRewards = source.HasAvailableRewards
      target.hasGeneratedRewards = source.HasGeneratedRewards
      target.hasInteraction = source.HasInteraction
      target.isWeeklyChestRetired = source.IsWeeklyChestRetired
      target.onUIInteract = source.OnUIInteract
      target.shouldShowFinalRetirementMessage = source.ShouldShowFinalRetirementMessage
      target.shouldShowRetirementMessage = source.ShouldShowRetirementMessage
    end
  end
  do
    local source = host.C_WorldLootObject
    if source then
      local target = {}
      api.worldLootObject = target
      target.doesSlotMatchInventoryType = source.DoesSlotMatchInventoryType
      target.getWorldLootObjectDistanceSquared = source.GetWorldLootObjectDistanceSquared
      target.getWorldLootObjectInfo = source.GetWorldLootObjectInfo
      target.getWorldLootObjectInfoByGUID = source.GetWorldLootObjectInfoByGUID
      target.isWorldLootObject = source.IsWorldLootObject
      target.isWorldLootObjectByGUID = source.IsWorldLootObjectByGUID
      target.isWorldLootObjectInRange = source.IsWorldLootObjectInRange
      target.onWorldLootObjectClick = source.OnWorldLootObjectClick
    end
  end
  do
    local source = host.C_WorldSafeLocsUIInternal
    if source then
      local target = {}
      api.worldSafeLocsUIInternal = target
      target.getWorldSafeLocs = source.GetWorldSafeLocs
    end
  end
  do
    local source = host.C_WorldStateInfo
    if source then
      local target = {}
      api.worldStateInfo = target
    end
  end
  do
    local source = host.C_WowEntitlementInfo
    if source then
      local target = {}
      api.wowEntitlementInfo = target
    end
  end
  do
    local source = host.C_WowSurvey
    if source then
      local target = {}
      api.wowSurvey = target
      target.openSurvey = source.OpenSurvey
      target.triggerSurveyServe = source.TriggerSurveyServe
    end
  end
  do
    local source = host.C_WowTokenUI
    if source then
      local target = {}
      api.wowTokenUI = target
      target.startTokenSell = source.StartTokenSell
    end
  end
  do
    local source = host.C_XMLUtil
    if source then
      local target = {}
      api.xmlUtil = target
      target.getTemplateInfo = source.GetTemplateInfo
      target.getTemplates = source.GetTemplates
    end
  end
  do
    local source = host.C_ZoneAbility
    if source then
      local target = {}
      api.zoneAbility = target
      target.getActiveAbilities = source.GetActiveAbilities
      target.getZoneAbilityIcon = source.GetZoneAbilityIcon
    end
  end
  do
    local target = {}
    api.zoneScript = target
    target.getAreaText = host.GetAreaText
    target.getMinimapZoneText = host.GetMinimapZoneText
    target.getRealZoneText = host.GetRealZoneText
    target.getSubZoneText = host.GetSubZoneText
    target.getZoneText = host.GetZoneText
  end
  api.events = {
    accountCharacterCurrencyDataReceived = "ACCOUNT_CHARACTER_CURRENCY_DATA_RECEIVED",
    accountCvarsLoaded = "ACCOUNT_CVARS_LOADED",
    accountMoney = "ACCOUNT_MONEY",
    accountStoreCurrencyAvailableUpdated = "ACCOUNT_STORE_CURRENCY_AVAILABLE_UPDATED",
    accountStoreFrontUpdated = "ACCOUNT_STORE_FRONT_UPDATED",
    accountStoreItemInfoUpdated = "ACCOUNT_STORE_ITEM_INFO_UPDATED",
    accountStoreTransactionError = "ACCOUNT_STORE_TRANSACTION_ERROR",
    achievementEarned = "ACHIEVEMENT_EARNED",
    achievementPlayerName = "ACHIEVEMENT_PLAYER_NAME",
    achievementSearchUpdated = "ACHIEVEMENT_SEARCH_UPDATED",
    actionRangeCheckUpdate = "ACTION_RANGE_CHECK_UPDATE",
    actionUsableChanged = "ACTION_USABLE_CHANGED",
    actionWillBindItem = "ACTION_WILL_BIND_ITEM",
    actionbarHidegrid = "ACTIONBAR_HIDEGRID",
    actionbarPageChanged = "ACTIONBAR_PAGE_CHANGED",
    actionbarShowBottomleft = "ACTIONBAR_SHOW_BOTTOMLEFT",
    actionbarShowgrid = "ACTIONBAR_SHOWGRID",
    actionbarSlotChanged = "ACTIONBAR_SLOT_CHANGED",
    actionbarUpdateCooldown = "ACTIONBAR_UPDATE_COOLDOWN",
    actionbarUpdateState = "ACTIONBAR_UPDATE_STATE",
    actionbarUpdateUsable = "ACTIONBAR_UPDATE_USABLE",
    activateGlyph = "ACTIVATE_GLYPH",
    activeCombatConfigChanged = "ACTIVE_COMBAT_CONFIG_CHANGED",
    activeDelveDataUpdate = "ACTIVE_DELVE_DATA_UPDATE",
    activeGameModeUpdated = "ACTIVE_GAME_MODE_UPDATED",
    activePlayerSpecializationChanged = "ACTIVE_PLAYER_SPECIALIZATION_CHANGED",
    activeTalentGroupChanged = "ACTIVE_TALENT_GROUP_CHANGED",
    adapterListChanged = "ADAPTER_LIST_CHANGED",
    addNeighborhoodCharterSignature = "ADD_NEIGHBORHOOD_CHARTER_SIGNATURE",
    addonActionBlocked = "ADDON_ACTION_BLOCKED",
    addonActionForbidden = "ADDON_ACTION_FORBIDDEN",
    addonLoaded = "ADDON_LOADED",
    addonRestrictionStateChanged = "ADDON_RESTRICTION_STATE_CHANGED",
    addonsUnloading = "ADDONS_UNLOADING",
    adventureMapClose = "ADVENTURE_MAP_CLOSE",
    adventureMapOpen = "ADVENTURE_MAP_OPEN",
    adventureMapQuestUpdate = "ADVENTURE_MAP_QUEST_UPDATE",
    adventureMapUpdateInsets = "ADVENTURE_MAP_UPDATE_INSETS",
    adventureMapUpdatePois = "ADVENTURE_MAP_UPDATE_POIS",
    ajDungeonAction = "AJ_DUNGEON_ACTION",
    ajOpen = "AJ_OPEN",
    ajOpenCollectionsAction = "AJ_OPEN_COLLECTIONS_ACTION",
    ajPveLfgAction = "AJ_PVE_LFG_ACTION",
    ajPvpAction = "AJ_PVP_ACTION",
    ajPvpLfgAction = "AJ_PVP_LFG_ACTION",
    ajPvpRbgAction = "AJ_PVP_RBG_ACTION",
    ajPvpSkirmishAction = "AJ_PVP_SKIRMISH_ACTION",
    ajPvpSpecialBgAction = "AJ_PVP_SPECIAL_BG_ACTION",
    ajPvpTrainingGroundsAction = "AJ_PVP_TRAINING_GROUNDS_ACTION",
    ajQuestLogOpen = "AJ_QUEST_LOG_OPEN",
    ajRaidAction = "AJ_RAID_ACTION",
    ajRefreshDisplay = "AJ_REFRESH_DISPLAY",
    ajRewardDataReceived = "AJ_REWARD_DATA_RECEIVED",
    alertRegionalChatDisabled = "ALERT_REGIONAL_CHAT_DISABLED",
    alliedRaceClose = "ALLIED_RACE_CLOSE",
    alliedRaceOpen = "ALLIED_RACE_OPEN",
    alternativeDefaultLanguageChanged = "ALTERNATIVE_DEFAULT_LANGUAGE_CHANGED",
    animaDiversionClose = "ANIMA_DIVERSION_CLOSE",
    animaDiversionOpen = "ANIMA_DIVERSION_OPEN",
    animaDiversionTalentUpdated = "ANIMA_DIVERSION_TALENT_UPDATED",
    archaeologyClosed = "ARCHAEOLOGY_CLOSED",
    archaeologyFindComplete = "ARCHAEOLOGY_FIND_COMPLETE",
    archaeologySurveyCast = "ARCHAEOLOGY_SURVEY_CAST",
    archaeologyToggle = "ARCHAEOLOGY_TOGGLE",
    areaPoisUpdated = "AREA_POIS_UPDATED",
    areaSpiritHealerInRange = "AREA_SPIRIT_HEALER_IN_RANGE",
    areaSpiritHealerOutOfRange = "AREA_SPIRIT_HEALER_OUT_OF_RANGE",
    arenaCooldownsUpdate = "ARENA_COOLDOWNS_UPDATE",
    arenaCrowdControlSpellUpdate = "ARENA_CROWD_CONTROL_SPELL_UPDATE",
    arenaOpponentUpdate = "ARENA_OPPONENT_UPDATE",
    arenaPrepOpponentSpecializations = "ARENA_PREP_OPPONENT_SPECIALIZATIONS",
    arenaSeasonWorldState = "ARENA_SEASON_WORLD_STATE",
    artifactClose = "ARTIFACT_CLOSE",
    artifactDigsiteComplete = "ARTIFACT_DIGSITE_COMPLETE",
    artifactEndgameRefund = "ARTIFACT_ENDGAME_REFUND",
    artifactRelicForgeClose = "ARTIFACT_RELIC_FORGE_CLOSE",
    artifactRelicForgePreviewRelicChanged = "ARTIFACT_RELIC_FORGE_PREVIEW_RELIC_CHANGED",
    artifactRelicForgeUpdate = "ARTIFACT_RELIC_FORGE_UPDATE",
    artifactRelicInfoReceived = "ARTIFACT_RELIC_INFO_RECEIVED",
    artifactRespecPrompt = "ARTIFACT_RESPEC_PROMPT",
    artifactTierChanged = "ARTIFACT_TIER_CHANGED",
    artifactUpdate = "ARTIFACT_UPDATE",
    artifactXpUpdate = "ARTIFACT_XP_UPDATE",
    assistedCombatActionSpellCast = "ASSISTED_COMBAT_ACTION_SPELL_CAST",
    auctionCanceled = "AUCTION_CANCELED",
    auctionHouseAuctionCreated = "AUCTION_HOUSE_AUCTION_CREATED",
    auctionHouseAuctionsExpired = "AUCTION_HOUSE_AUCTIONS_EXPIRED",
    auctionHouseBrowseFailure = "AUCTION_HOUSE_BROWSE_FAILURE",
    auctionHouseBrowseResultsAdded = "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
    auctionHouseBrowseResultsUpdated = "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
    auctionHouseClosed = "AUCTION_HOUSE_CLOSED",
    auctionHouseDisabled = "AUCTION_HOUSE_DISABLED",
    auctionHouseFavoritesUpdated = "AUCTION_HOUSE_FAVORITES_UPDATED",
    auctionHouseItemDeliveryDelayUpdate = "AUCTION_HOUSE_ITEM_DELIVERY_DELAY_UPDATE",
    auctionHouseNewBidReceived = "AUCTION_HOUSE_NEW_BID_RECEIVED",
    auctionHouseNewResultsReceived = "AUCTION_HOUSE_NEW_RESULTS_RECEIVED",
    auctionHousePostError = "AUCTION_HOUSE_POST_ERROR",
    auctionHousePostWarning = "AUCTION_HOUSE_POST_WARNING",
    auctionHousePurchaseCompleted = "AUCTION_HOUSE_PURCHASE_COMPLETED",
    auctionHouseScriptDeprecated = "AUCTION_HOUSE_SCRIPT_DEPRECATED",
    auctionHouseShow = "AUCTION_HOUSE_SHOW",
    auctionHouseShowCommodityWonNotification = "AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION",
    auctionHouseShowError = "AUCTION_HOUSE_SHOW_ERROR",
    auctionHouseShowFormattedNotification = "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION",
    auctionHouseShowNotification = "AUCTION_HOUSE_SHOW_NOTIFICATION",
    auctionHouseThrottledMessageDropped = "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
    auctionHouseThrottledMessageQueued = "AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED",
    auctionHouseThrottledMessageResponseReceived = "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED",
    auctionHouseThrottledMessageSent = "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT",
    auctionHouseThrottledSystemReady = "AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
    auctionMultisellFailure = "AUCTION_MULTISELL_FAILURE",
    auctionMultisellStart = "AUCTION_MULTISELL_START",
    auctionMultisellUpdate = "AUCTION_MULTISELL_UPDATE",
    auraDataProviderSwitch = "AURA_DATA_PROVIDER_SWITCH",
    autofollowBegin = "AUTOFOLLOW_BEGIN",
    autofollowEnd = "AUTOFOLLOW_END",
    availableGameModesUpdated = "AVAILABLE_GAME_MODES_UPDATED",
    avatarListUpdated = "AVATAR_LIST_UPDATED",
    avoidanceUpdate = "AVOIDANCE_UPDATE",
    azeriteEmpoweredItemEquippedStatusChanged = "AZERITE_EMPOWERED_ITEM_EQUIPPED_STATUS_CHANGED",
    azeriteEmpoweredItemLooted = "AZERITE_EMPOWERED_ITEM_LOOTED",
    azeriteEmpoweredItemSelectionUpdated = "AZERITE_EMPOWERED_ITEM_SELECTION_UPDATED",
    azeriteEssenceActivated = "AZERITE_ESSENCE_ACTIVATED",
    azeriteEssenceActivationFailed = "AZERITE_ESSENCE_ACTIVATION_FAILED",
    azeriteEssenceChanged = "AZERITE_ESSENCE_CHANGED",
    azeriteEssenceForgeClose = "AZERITE_ESSENCE_FORGE_CLOSE",
    azeriteEssenceForgeOpen = "AZERITE_ESSENCE_FORGE_OPEN",
    azeriteEssenceMilestoneUnlocked = "AZERITE_ESSENCE_MILESTONE_UNLOCKED",
    azeriteEssenceUpdate = "AZERITE_ESSENCE_UPDATE",
    azeriteItemEnabledStateChanged = "AZERITE_ITEM_ENABLED_STATE_CHANGED",
    azeriteItemExperienceChanged = "AZERITE_ITEM_EXPERIENCE_CHANGED",
    azeriteItemPowerLevelChanged = "AZERITE_ITEM_POWER_LEVEL_CHANGED",
    bagClosed = "BAG_CLOSED",
    bagContainerUpdate = "BAG_CONTAINER_UPDATE",
    bagNewItemsUpdated = "BAG_NEW_ITEMS_UPDATED",
    bagOpen = "BAG_OPEN",
    bagOverflowWithFullInventory = "BAG_OVERFLOW_WITH_FULL_INVENTORY",
    bagSlotFlagsUpdated = "BAG_SLOT_FLAGS_UPDATED",
    bagUpdate = "BAG_UPDATE",
    bagUpdateCooldown = "BAG_UPDATE_COOLDOWN",
    bagUpdateDelayed = "BAG_UPDATE_DELAYED",
    bankBagSlotFlagsUpdated = "BANK_BAG_SLOT_FLAGS_UPDATED",
    bankTabSettingsUpdated = "BANK_TAB_SETTINGS_UPDATED",
    bankTabsChanged = "BANK_TABS_CHANGED",
    bankframeClosed = "BANKFRAME_CLOSED",
    bankframeOpened = "BANKFRAME_OPENED",
    barberShopAppearanceApplied = "BARBER_SHOP_APPEARANCE_APPLIED",
    barberShopCameraValuesUpdated = "BARBER_SHOP_CAMERA_VALUES_UPDATED",
    barberShopClose = "BARBER_SHOP_CLOSE",
    barberShopCostUpdate = "BARBER_SHOP_COST_UPDATE",
    barberShopForceCustomizationsUpdate = "BARBER_SHOP_FORCE_CUSTOMIZATIONS_UPDATE",
    barberShopOpen = "BARBER_SHOP_OPEN",
    barberShopResult = "BARBER_SHOP_RESULT",
    battleNetFriendTagEnabledStatusUpdated = "BATTLE_NET_FRIEND_TAG_ENABLED_STATUS_UPDATED",
    battleNetTitleFriendCustomNameEnabledStatusUpdated = "BATTLE_NET_TITLE_FRIEND_CUSTOM_NAME_ENABLED_STATUS_UPDATED",
    battlePetCursorClear = "BATTLE_PET_CURSOR_CLEAR",
    battlefieldAutoQueue = "BATTLEFIELD_AUTO_QUEUE",
    battlefieldAutoQueueEject = "BATTLEFIELD_AUTO_QUEUE_EJECT",
    battlefieldQueueTimeout = "BATTLEFIELD_QUEUE_TIMEOUT",
    battlefieldsClosed = "BATTLEFIELDS_CLOSED",
    battlefieldsShow = "BATTLEFIELDS_SHOW",
    battlegroundObjectivesUpdate = "BATTLEGROUND_OBJECTIVES_UPDATE",
    battlegroundPointsUpdate = "BATTLEGROUND_POINTS_UPDATE",
    battlepetForceNameDeclension = "BATTLEPET_FORCE_NAME_DECLENSION",
    behavioralNotification = "BEHAVIORAL_NOTIFICATION",
    bidAdded = "BID_ADDED",
    bidsUpdated = "BIDS_UPDATED",
    bindEnchant = "BIND_ENCHANT",
    bindingsLoaded = "BINDINGS_LOADED",
    blackMarketBidResult = "BLACK_MARKET_BID_RESULT",
    blackMarketClose = "BLACK_MARKET_CLOSE",
    blackMarketItemUpdate = "BLACK_MARKET_ITEM_UPDATE",
    blackMarketOpen = "BLACK_MARKET_OPEN",
    blackMarketOutbid = "BLACK_MARKET_OUTBID",
    blackMarketUnavailable = "BLACK_MARKET_UNAVAILABLE",
    blackMarketWon = "BLACK_MARKET_WON",
    bnBlockFailedTooMany = "BN_BLOCK_FAILED_TOO_MANY",
    bnBlockListUpdated = "BN_BLOCK_LIST_UPDATED",
    bnChatMsgAddon = "BN_CHAT_MSG_ADDON",
    bnChatWhisperUndeliverable = "BN_CHAT_WHISPER_UNDELIVERABLE",
    bnConnected = "BN_CONNECTED",
    bnCustomMessageChanged = "BN_CUSTOM_MESSAGE_CHANGED",
    bnCustomMessageLoaded = "BN_CUSTOM_MESSAGE_LOADED",
    bnDisconnected = "BN_DISCONNECTED",
    bnFriendAccountOffline = "BN_FRIEND_ACCOUNT_OFFLINE",
    bnFriendAccountOnline = "BN_FRIEND_ACCOUNT_ONLINE",
    bnFriendInfoChanged = "BN_FRIEND_INFO_CHANGED",
    bnFriendInviteAdded = "BN_FRIEND_INVITE_ADDED",
    bnFriendInviteListInitialized = "BN_FRIEND_INVITE_LIST_INITIALIZED",
    bnFriendInviteRemoved = "BN_FRIEND_INVITE_REMOVED",
    bnFriendListSizeChanged = "BN_FRIEND_LIST_SIZE_CHANGED",
    bnInfoChanged = "BN_INFO_CHANGED",
    bnRequestFofSucceeded = "BN_REQUEST_FOF_SUCCEEDED",
    bnetNeighborhoodListUpdated = "B_NET_NEIGHBORHOOD_LIST_UPDATED",
    bnetRequestInviteConfirmation = "BNET_REQUEST_INVITE_CONFIRMATION",
    bonusRollActivate = "BONUS_ROLL_ACTIVATE",
    bonusRollDeactivate = "BONUS_ROLL_DEACTIVATE",
    bonusRollFailed = "BONUS_ROLL_FAILED",
    bonusRollResult = "BONUS_ROLL_RESULT",
    bonusRollStarted = "BONUS_ROLL_STARTED",
    bossKill = "BOSS_KILL",
    bulkPurchaseResultReceived = "BULK_PURCHASE_RESULT_RECEIVED",
    bulkRefundResultReceived = "BULK_REFUND_RESULT_RECEIVED",
    calendarActionPending = "CALENDAR_ACTION_PENDING",
    calendarCloseEvent = "CALENDAR_CLOSE_EVENT",
    calendarEventAlarm = "CALENDAR_EVENT_ALARM",
    calendarNewEvent = "CALENDAR_NEW_EVENT",
    calendarOpenEvent = "CALENDAR_OPEN_EVENT",
    calendarUpdateError = "CALENDAR_UPDATE_ERROR",
    calendarUpdateErrorWithCount = "CALENDAR_UPDATE_ERROR_WITH_COUNT",
    calendarUpdateErrorWithPlayerName = "CALENDAR_UPDATE_ERROR_WITH_PLAYER_NAME",
    calendarUpdateEvent = "CALENDAR_UPDATE_EVENT",
    calendarUpdateEventList = "CALENDAR_UPDATE_EVENT_LIST",
    calendarUpdateGuildEvents = "CALENDAR_UPDATE_GUILD_EVENTS",
    calendarUpdateInviteList = "CALENDAR_UPDATE_INVITE_LIST",
    calendarUpdatePendingInvites = "CALENDAR_UPDATE_PENDING_INVITES",
    canLocalWhisperTargetResponse = "CAN_LOCAL_WHISPER_TARGET_RESPONSE",
    canPlayerSpeakLanguageChanged = "CAN_PLAYER_SPEAK_LANGUAGE_CHANGED",
    cancelAllLootRolls = "CANCEL_ALL_LOOT_ROLLS",
    cancelGlyphCast = "CANCEL_GLYPH_CAST",
    cancelLootRoll = "CANCEL_LOOT_ROLL",
    cancelNeighborhoodInviteResponse = "CANCEL_NEIGHBORHOOD_INVITE_RESPONSE",
    cancelPlayerCountdown = "CANCEL_PLAYER_COUNTDOWN",
    cancelSummon = "CANCEL_SUMMON",
    captureframesFailed = "CAPTUREFRAMES_FAILED",
    captureframesSucceeded = "CAPTUREFRAMES_SUCCEEDED",
    catalogShopAddPendingProduct = "CATALOG_SHOP_ADD_PENDING_PRODUCT",
    catalogShopDataRefresh = "CATALOG_SHOP_DATA_REFRESH",
    catalogShopDisabled = "CATALOG_SHOP_DISABLED",
    catalogShopFetchFailure = "CATALOG_SHOP_FETCH_FAILURE",
    catalogShopFetchSuccess = "CATALOG_SHOP_FETCH_SUCCESS",
    catalogShopOpenSimpleCheckout = "CATALOG_SHOP_OPEN_SIMPLE_CHECKOUT",
    catalogShopPurchaseSuccess = "CATALOG_SHOP_PURCHASE_SUCCESS",
    catalogShopRebuildScrollBox = "CATALOG_SHOP_REBUILD_SCROLL_BOX",
    catalogShopRefundableDecorsUpdated = "CATALOG_SHOP_REFUNDABLE_DECORS_UPDATED",
    catalogShopRemovePendingProduct = "CATALOG_SHOP_REMOVE_PENDING_PRODUCT",
    catalogShopResultError = "CATALOG_SHOP_RESULT_ERROR",
    catalogShopSpecificProductRefresh = "CATALOG_SHOP_SPECIFIC_PRODUCT_REFRESH",
    catalogShopVirtualCurrencyBalanceUpdate = "CATALOG_SHOP_VIRTUAL_CURRENCY_BALANCE_UPDATE",
    catalogShopVirtualCurrencyBalanceUpdateFailure = "CATALOG_SHOP_VIRTUAL_CURRENCY_BALANCE_UPDATE_FAILURE",
    cautionaryChannelMessage = "CAUTIONARY_CHANNEL_MESSAGE",
    cautionaryChatMessage = "CAUTIONARY_CHAT_MESSAGE",
    cemeteryPreferenceUpdated = "CEMETERY_PREFERENCE_UPDATED",
    challengeModeCompleted = "CHALLENGE_MODE_COMPLETED",
    challengeModeCompletedRewards = "CHALLENGE_MODE_COMPLETED_REWARDS",
    challengeModeDeathCountUpdated = "CHALLENGE_MODE_DEATH_COUNT_UPDATED",
    challengeModeKeystoneReceptableOpen = "CHALLENGE_MODE_KEYSTONE_RECEPTABLE_OPEN",
    challengeModeKeystoneSlotted = "CHALLENGE_MODE_KEYSTONE_SLOTTED",
    challengeModeLeaderboardResult = "CHALLENGE_MODE_LEADERBOARD_RESULT",
    challengeModeLeadersUpdate = "CHALLENGE_MODE_LEADERS_UPDATE",
    challengeModeLeaverTimerEnded = "CHALLENGE_MODE_LEAVER_TIMER_ENDED",
    challengeModeLeaverTimerStarted = "CHALLENGE_MODE_LEAVER_TIMER_STARTED",
    challengeModeMapsUpdate = "CHALLENGE_MODE_MAPS_UPDATE",
    challengeModeMemberInfoUpdated = "CHALLENGE_MODE_MEMBER_INFO_UPDATED",
    challengeModeNewRecord = "CHALLENGE_MODE_NEW_RECORD",
    challengeModeReset = "CHALLENGE_MODE_RESET",
    challengeModeStart = "CHALLENGE_MODE_START",
    channelCountUpdate = "CHANNEL_COUNT_UPDATE",
    channelFlagsUpdated = "CHANNEL_FLAGS_UPDATED",
    channelInviteRequest = "CHANNEL_INVITE_REQUEST",
    channelLeft = "CHANNEL_LEFT",
    channelPasswordRequest = "CHANNEL_PASSWORD_REQUEST",
    channelRosterUpdate = "CHANNEL_ROSTER_UPDATE",
    channelUiUpdate = "CHANNEL_UI_UPDATE",
    characterItemFixupNotification = "CHARACTER_ITEM_FIXUP_NOTIFICATION",
    characterPointsChanged = "CHARACTER_POINTS_CHANGED",
    characterUpgradeSpellTierSet = "CHARACTER_UPGRADE_SPELL_TIER_SET",
    chatCombatMsgArenaPointsGain = "CHAT_COMBAT_MSG_ARENA_POINTS_GAIN",
    chatDisabledChangeFailed = "CHAT_DISABLED_CHANGE_FAILED",
    chatDisabledChanged = "CHAT_DISABLED_CHANGED",
    chatLoggingChanged = "CHAT_LOGGING_CHANGED",
    chatMsgAchievement = "CHAT_MSG_ACHIEVEMENT",
    chatMsgAddon = "CHAT_MSG_ADDON",
    chatMsgAddonLogged = "CHAT_MSG_ADDON_LOGGED",
    chatMsgAfk = "CHAT_MSG_AFK",
    chatMsgBgSystemAlliance = "CHAT_MSG_BG_SYSTEM_ALLIANCE",
    chatMsgBgSystemHorde = "CHAT_MSG_BG_SYSTEM_HORDE",
    chatMsgBgSystemNeutral = "CHAT_MSG_BG_SYSTEM_NEUTRAL",
    chatMsgBn = "CHAT_MSG_BN",
    chatMsgBnInlineToastAlert = "CHAT_MSG_BN_INLINE_TOAST_ALERT",
    chatMsgBnInlineToastBroadcast = "CHAT_MSG_BN_INLINE_TOAST_BROADCAST",
    chatMsgBnInlineToastBroadcastInform = "CHAT_MSG_BN_INLINE_TOAST_BROADCAST_INFORM",
    chatMsgBnInlineToastConversation = "CHAT_MSG_BN_INLINE_TOAST_CONVERSATION",
    chatMsgBnWhisper = "CHAT_MSG_BN_WHISPER",
    chatMsgBnWhisperInform = "CHAT_MSG_BN_WHISPER_INFORM",
    chatMsgBnWhisperPlayerOffline = "CHAT_MSG_BN_WHISPER_PLAYER_OFFLINE",
    chatMsgChannel = "CHAT_MSG_CHANNEL",
    chatMsgChannelJoin = "CHAT_MSG_CHANNEL_JOIN",
    chatMsgChannelLeave = "CHAT_MSG_CHANNEL_LEAVE",
    chatMsgChannelLeavePrevented = "CHAT_MSG_CHANNEL_LEAVE_PREVENTED",
    chatMsgChannelList = "CHAT_MSG_CHANNEL_LIST",
    chatMsgChannelNotice = "CHAT_MSG_CHANNEL_NOTICE",
    chatMsgChannelNoticeUser = "CHAT_MSG_CHANNEL_NOTICE_USER",
    chatMsgCombatFactionChange = "CHAT_MSG_COMBAT_FACTION_CHANGE",
    chatMsgCombatHonorGain = "CHAT_MSG_COMBAT_HONOR_GAIN",
    chatMsgCombatMiscInfo = "CHAT_MSG_COMBAT_MISC_INFO",
    chatMsgCombatXpGain = "CHAT_MSG_COMBAT_XP_GAIN",
    chatMsgCommunitiesChannel = "CHAT_MSG_COMMUNITIES_CHANNEL",
    chatMsgCurrency = "CHAT_MSG_CURRENCY",
    chatMsgDnd = "CHAT_MSG_DND",
    chatMsgEmote = "CHAT_MSG_EMOTE",
    chatMsgFiltered = "CHAT_MSG_FILTERED",
    chatMsgGuild = "CHAT_MSG_GUILD",
    chatMsgGuildAchievement = "CHAT_MSG_GUILD_ACHIEVEMENT",
    chatMsgGuildDiscord = "CHAT_MSG_GUILD_DISCORD",
    chatMsgGuildItemLooted = "CHAT_MSG_GUILD_ITEM_LOOTED",
    chatMsgIgnored = "CHAT_MSG_IGNORED",
    chatMsgInstanceChat = "CHAT_MSG_INSTANCE_CHAT",
    chatMsgInstanceChatLeader = "CHAT_MSG_INSTANCE_CHAT_LEADER",
    chatMsgLoot = "CHAT_MSG_LOOT",
    chatMsgMoney = "CHAT_MSG_MONEY",
    chatMsgMonsterEmote = "CHAT_MSG_MONSTER_EMOTE",
    chatMsgMonsterParty = "CHAT_MSG_MONSTER_PARTY",
    chatMsgMonsterSay = "CHAT_MSG_MONSTER_SAY",
    chatMsgMonsterWhisper = "CHAT_MSG_MONSTER_WHISPER",
    chatMsgMonsterYell = "CHAT_MSG_MONSTER_YELL",
    chatMsgOfficer = "CHAT_MSG_OFFICER",
    chatMsgOpening = "CHAT_MSG_OPENING",
    chatMsgParty = "CHAT_MSG_PARTY",
    chatMsgPartyLeader = "CHAT_MSG_PARTY_LEADER",
    chatMsgPetBattleCombatLog = "CHAT_MSG_PET_BATTLE_COMBAT_LOG",
    chatMsgPetBattleInfo = "CHAT_MSG_PET_BATTLE_INFO",
    chatMsgPetInfo = "CHAT_MSG_PET_INFO",
    chatMsgPing = "CHAT_MSG_PING",
    chatMsgRaid = "CHAT_MSG_RAID",
    chatMsgRaidBossEmote = "CHAT_MSG_RAID_BOSS_EMOTE",
    chatMsgRaidBossWhisper = "CHAT_MSG_RAID_BOSS_WHISPER",
    chatMsgRaidLeader = "CHAT_MSG_RAID_LEADER",
    chatMsgRaidWarning = "CHAT_MSG_RAID_WARNING",
    chatMsgRestricted = "CHAT_MSG_RESTRICTED",
    chatMsgSay = "CHAT_MSG_SAY",
    chatMsgSkill = "CHAT_MSG_SKILL",
    chatMsgSystem = "CHAT_MSG_SYSTEM",
    chatMsgTargeticons = "CHAT_MSG_TARGETICONS",
    chatMsgTextEmote = "CHAT_MSG_TEXT_EMOTE",
    chatMsgTradeskills = "CHAT_MSG_TRADESKILLS",
    chatMsgVoiceText = "CHAT_MSG_VOICE_TEXT",
    chatMsgWhisper = "CHAT_MSG_WHISPER",
    chatMsgWhisperInform = "CHAT_MSG_WHISPER_INFORM",
    chatMsgYell = "CHAT_MSG_YELL",
    chatRegionalSendFailed = "CHAT_REGIONAL_SEND_FAILED",
    chatRegionalStatusChanged = "CHAT_REGIONAL_STATUS_CHANGED",
    chatServerDisconnected = "CHAT_SERVER_DISCONNECTED",
    chatServerReconnected = "CHAT_SERVER_RECONNECTED",
    chestRewardsUpdatedFromServer = "CHEST_REWARDS_UPDATED_FROM_SERVER",
    cinematicStart = "CINEMATIC_START",
    cinematicStop = "CINEMATIC_STOP",
    classTalentsSwitchToLoadoutByIndex = "CLASS_TALENTS_SWITCH_TO_LOADOUT_BY_INDEX",
    classTalentsSwitchToLoadoutByName = "CLASS_TALENTS_SWITCH_TO_LOADOUT_BY_NAME",
    classTalentsSwitchToSpecializationByIndex = "CLASS_TALENTS_SWITCH_TO_SPECIALIZATION_BY_INDEX",
    classTalentsSwitchToSpecializationByName = "CLASS_TALENTS_SWITCH_TO_SPECIALIZATION_BY_NAME",
    classTrialTimerStart = "CLASS_TRIAL_TIMER_START",
    classTrialUpgradeComplete = "CLASS_TRIAL_UPGRADE_COMPLETE",
    clearBossEmotes = "CLEAR_BOSS_EMOTES",
    clickbindingsSetHighlightsShown = "CLICKBINDINGS_SET_HIGHLIGHTS_SHOWN",
    clientSceneClosed = "CLIENT_SCENE_CLOSED",
    clientSceneOpened = "CLIENT_SCENE_OPENED",
    closeCharterConfirmationUI = "CLOSE_CHARTER_CONFIRMATION_UI",
    closeCreateCharterNeighborhoodUI = "CLOSE_CREATE_CHARTER_NEIGHBORHOOD_UI",
    closeCreateGuildNeighborhoodUI = "CLOSE_CREATE_GUILD_NEIGHBORHOOD_UI",
    closeInboxItem = "CLOSE_INBOX_ITEM",
    closePlotCornerstone = "CLOSE_PLOT_CORNERSTONE",
    closeTabardFrame = "CLOSE_TABARD_FRAME",
    clubAdded = "CLUB_ADDED",
    clubError = "CLUB_ERROR",
    clubFinderApplicantInviteRecieved = "CLUB_FINDER_APPLICANT_INVITE_RECIEVED",
    clubFinderApplicationsUpdated = "CLUB_FINDER_APPLICATIONS_UPDATED",
    clubFinderCanWhisperApplicant = "CLUB_FINDER_CAN_WHISPER_APPLICANT",
    clubFinderClubListReturned = "CLUB_FINDER_CLUB_LIST_RETURNED",
    clubFinderClubReported = "CLUB_FINDER_CLUB_REPORTED",
    clubFinderCommunityOfflineJoin = "CLUB_FINDER_COMMUNITY_OFFLINE_JOIN",
    clubFinderEnabledOrDisabled = "CLUB_FINDER_ENABLED_OR_DISABLED",
    clubFinderGuildRealmNameUpdated = "CLUB_FINDER_GUILD_REALM_NAME_UPDATED",
    clubFinderLinkedClubReturned = "CLUB_FINDER_LINKED_CLUB_RETURNED",
    clubFinderMembershipListChanged = "CLUB_FINDER_MEMBERSHIP_LIST_CHANGED",
    clubFinderPlayerPendingListRecieved = "CLUB_FINDER_PLAYER_PENDING_LIST_RECIEVED",
    clubFinderPostUpdated = "CLUB_FINDER_POST_UPDATED",
    clubFinderRecruitListChanged = "CLUB_FINDER_RECRUIT_LIST_CHANGED",
    clubFinderRecruitmentPostReturned = "CLUB_FINDER_RECRUITMENT_POST_RETURNED",
    clubFinderRecruitsUpdated = "CLUB_FINDER_RECRUITS_UPDATED",
    clubInvitationAddedForSelf = "CLUB_INVITATION_ADDED_FOR_SELF",
    clubInvitationRemovedForSelf = "CLUB_INVITATION_REMOVED_FOR_SELF",
    clubInvitationsReceivedForClub = "CLUB_INVITATIONS_RECEIVED_FOR_CLUB",
    clubMemberAdded = "CLUB_MEMBER_ADDED",
    clubMemberPresenceUpdated = "CLUB_MEMBER_PRESENCE_UPDATED",
    clubMemberRemoved = "CLUB_MEMBER_REMOVED",
    clubMemberRoleUpdated = "CLUB_MEMBER_ROLE_UPDATED",
    clubMemberUpdated = "CLUB_MEMBER_UPDATED",
    clubMembersUpdated = "CLUB_MEMBERS_UPDATED",
    clubMessageAdded = "CLUB_MESSAGE_ADDED",
    clubMessageHistoryReceived = "CLUB_MESSAGE_HISTORY_RECEIVED",
    clubMessageUpdated = "CLUB_MESSAGE_UPDATED",
    clubRemoved = "CLUB_REMOVED",
    clubRemovedMessage = "CLUB_REMOVED_MESSAGE",
    clubSelfMemberRoleUpdated = "CLUB_SELF_MEMBER_ROLE_UPDATED",
    clubStreamAdded = "CLUB_STREAM_ADDED",
    clubStreamRemoved = "CLUB_STREAM_REMOVED",
    clubStreamSubscribed = "CLUB_STREAM_SUBSCRIBED",
    clubStreamUnsubscribed = "CLUB_STREAM_UNSUBSCRIBED",
    clubStreamUpdated = "CLUB_STREAM_UPDATED",
    clubStreamsLoaded = "CLUB_STREAMS_LOADED",
    clubTicketCreated = "CLUB_TICKET_CREATED",
    clubTicketReceived = "CLUB_TICKET_RECEIVED",
    clubTicketsReceived = "CLUB_TICKETS_RECEIVED",
    clubUpdated = "CLUB_UPDATED",
    colorOverrideUpdated = "COLOR_OVERRIDE_UPDATED",
    colorOverridesReset = "COLOR_OVERRIDES_RESET",
    combatLogApplyFilterSettings = "COMBAT_LOG_APPLY_FILTER_SETTINGS",
    combatLogEntriesCleared = "COMBAT_LOG_ENTRIES_CLEARED",
    combatLogEvent = "COMBAT_LOG_EVENT",
    combatLogEventInternalUnfiltered = "COMBAT_LOG_EVENT_INTERNAL_UNFILTERED",
    combatLogEventUnfiltered = "COMBAT_LOG_EVENT_UNFILTERED",
    combatLogMessage = "COMBAT_LOG_MESSAGE",
    combatLogMessageLimitChanged = "COMBAT_LOG_MESSAGE_LIMIT_CHANGED",
    combatLogRefilterEntries = "COMBAT_LOG_REFILTER_ENTRIES",
    combatRatingUpdate = "COMBAT_RATING_UPDATE",
    combatTextUpdate = "COMBAT_TEXT_UPDATE",
    comboTargetChanged = "COMBO_TARGET_CHANGED",
    commentatorCombatEvent = "COMMENTATOR_COMBAT_EVENT",
    commentatorEnterWorld = "COMMENTATOR_ENTER_WORLD",
    commentatorHistoryFlushed = "COMMENTATOR_HISTORY_FLUSHED",
    commentatorImmediateFovUpdate = "COMMENTATOR_IMMEDIATE_FOV_UPDATE",
    commentatorMapUpdate = "COMMENTATOR_MAP_UPDATE",
    commentatorPlayerNameOverrideUpdate = "COMMENTATOR_PLAYER_NAME_OVERRIDE_UPDATE",
    commentatorPlayerUpdate = "COMMENTATOR_PLAYER_UPDATE",
    commentatorResetSettings = "COMMENTATOR_RESET_SETTINGS",
    commentatorTeamNameUpdate = "COMMENTATOR_TEAM_NAME_UPDATE",
    commentatorTeamsSwapped = "COMMENTATOR_TEAMS_SWAPPED",
    commodityPriceUnavailable = "COMMODITY_PRICE_UNAVAILABLE",
    commodityPriceUpdated = "COMMODITY_PRICE_UPDATED",
    commodityPurchaseFailed = "COMMODITY_PURCHASE_FAILED",
    commodityPurchaseSucceeded = "COMMODITY_PURCHASE_SUCCEEDED",
    commodityPurchased = "COMMODITY_PURCHASED",
    commoditySearchResultsAdded = "COMMODITY_SEARCH_RESULTS_ADDED",
    commoditySearchResultsReceived = "COMMODITY_SEARCH_RESULTS_RECEIVED",
    commoditySearchResultsUpdated = "COMMODITY_SEARCH_RESULTS_UPDATED",
    compactUnitFrameProfilesLoaded = "COMPACT_UNIT_FRAME_PROFILES_LOADED",
    companionLearned = "COMPANION_LEARNED",
    companionUnlearned = "COMPANION_UNLEARNED",
    companionUpdate = "COMPANION_UPDATE",
    configCommitFailed = "CONFIG_COMMIT_FAILED",
    confirmBattleNetFriendInviteShow = "CONFIRM_BATTLE_NET_FRIEND_INVITE_SHOW",
    confirmBeforeUse = "CONFIRM_BEFORE_USE",
    confirmBinder = "CONFIRM_BINDER",
    confirmDisenchantRoll = "CONFIRM_DISENCHANT_ROLL",
    confirmLootRoll = "CONFIRM_LOOT_ROLL",
    confirmPetUnlearn = "CONFIRM_PET_UNLEARN",
    confirmSummon = "CONFIRM_SUMMON",
    confirmTalentWipe = "CONFIRM_TALENT_WIPE",
    confirmXpLoss = "CONFIRM_XP_LOSS",
    consoleClear = "CONSOLE_CLEAR",
    consoleColorsChanged = "CONSOLE_COLORS_CHANGED",
    consoleFontSizeChanged = "CONSOLE_FONT_SIZE_CHANGED",
    consoleLog = "CONSOLE_LOG",
    consoleMessage = "CONSOLE_MESSAGE",
    contentTrackingIsEnabledUpdate = "CONTENT_TRACKING_IS_ENABLED_UPDATE",
    contentTrackingListUpdate = "CONTENT_TRACKING_LIST_UPDATE",
    contentTrackingUpdate = "CONTENT_TRACKING_UPDATE",
    contributionChanged = "CONTRIBUTION_CHANGED",
    contributionCollectorPending = "CONTRIBUTION_COLLECTOR_PENDING",
    contributionCollectorUpdate = "CONTRIBUTION_COLLECTOR_UPDATE",
    contributionCollectorUpdateSingle = "CONTRIBUTION_COLLECTOR_UPDATE_SINGLE",
    convertToBindToAccountConfirm = "CONVERT_TO_BIND_TO_ACCOUNT_CONFIRM",
    convertToRaidConfirmation = "CONVERT_TO_RAID_CONFIRMATION",
    cooldownViewerDataLoaded = "COOLDOWN_VIEWER_DATA_LOADED",
    cooldownViewerSpellOverrideUpdated = "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED",
    cooldownViewerTableHotfixed = "COOLDOWN_VIEWER_TABLE_HOTFIXED",
    corpseInInstance = "CORPSE_IN_INSTANCE",
    corpseInRange = "CORPSE_IN_RANGE",
    corpseOutOfRange = "CORPSE_OUT_OF_RANGE",
    covenantCallingsUpdated = "COVENANT_CALLINGS_UPDATED",
    covenantChosen = "COVENANT_CHOSEN",
    covenantPreviewClose = "COVENANT_PREVIEW_CLOSE",
    covenantPreviewOpen = "COVENANT_PREVIEW_OPEN",
    covenantRenownCatchUpStateUpdate = "COVENANT_RENOWN_CATCH_UP_STATE_UPDATE",
    covenantSanctumRenownLevelChanged = "COVENANT_SANCTUM_RENOWN_LEVEL_CHANGED",
    craftingDetailsUpdate = "CRAFTING_DETAILS_UPDATE",
    craftingHouseDisabled = "CRAFTING_HOUSE_DISABLED",
    craftingordersCanRequest = "CRAFTINGORDERS_CAN_REQUEST",
    craftingordersClaimOrderResponse = "CRAFTINGORDERS_CLAIM_ORDER_RESPONSE",
    craftingordersClaimedOrderAdded = "CRAFTINGORDERS_CLAIMED_ORDER_ADDED",
    craftingordersClaimedOrderRemoved = "CRAFTINGORDERS_CLAIMED_ORDER_REMOVED",
    craftingordersClaimedOrderUpdated = "CRAFTINGORDERS_CLAIMED_ORDER_UPDATED",
    craftingordersCraftOrderResponse = "CRAFTINGORDERS_CRAFT_ORDER_RESPONSE",
    craftingordersCustomerFavoritesChanged = "CRAFTINGORDERS_CUSTOMER_FAVORITES_CHANGED",
    craftingordersCustomerOptionsParsed = "CRAFTINGORDERS_CUSTOMER_OPTIONS_PARSED",
    craftingordersDisplayCrafterFulfilledMsg = "CRAFTINGORDERS_DISPLAY_CRAFTER_FULFILLED_MSG",
    craftingordersFulfillOrderResponse = "CRAFTINGORDERS_FULFILL_ORDER_RESPONSE",
    craftingordersHideCrafter = "CRAFTINGORDERS_HIDE_CRAFTER",
    craftingordersHideCustomer = "CRAFTINGORDERS_HIDE_CUSTOMER",
    craftingordersOrderCancelResponse = "CRAFTINGORDERS_ORDER_CANCEL_RESPONSE",
    craftingordersOrderPlacementResponse = "CRAFTINGORDERS_ORDER_PLACEMENT_RESPONSE",
    craftingordersRejectOrderResponse = "CRAFTINGORDERS_REJECT_ORDER_RESPONSE",
    craftingordersReleaseOrderResponse = "CRAFTINGORDERS_RELEASE_ORDER_RESPONSE",
    craftingordersShowCrafter = "CRAFTINGORDERS_SHOW_CRAFTER",
    craftingordersShowCustomer = "CRAFTINGORDERS_SHOW_CUSTOMER",
    craftingordersUnexpectedError = "CRAFTINGORDERS_UNEXPECTED_ERROR",
    craftingordersUpdateCustomerName = "CRAFTINGORDERS_UPDATE_CUSTOMER_NAME",
    craftingordersUpdateOrderCount = "CRAFTINGORDERS_UPDATE_ORDER_COUNT",
    craftingordersUpdatePersonalOrderCounts = "CRAFTINGORDERS_UPDATE_PERSONAL_ORDER_COUNTS",
    craftingordersUpdateRewards = "CRAFTINGORDERS_UPDATE_REWARDS",
    createNeighborhoodResult = "CREATE_NEIGHBORHOOD_RESULT",
    criteriaComplete = "CRITERIA_COMPLETE",
    criteriaEarned = "CRITERIA_EARNED",
    criteriaUpdate = "CRITERIA_UPDATE",
    currencyDisplayUpdate = "CURRENCY_DISPLAY_UPDATE",
    currencyTransferFailed = "CURRENCY_TRANSFER_FAILED",
    currencyTransferInitiated = "CURRENCY_TRANSFER_INITIATED",
    currencyTransferLogUpdate = "CURRENCY_TRANSFER_LOG_UPDATE",
    currencyTransferSuccess = "CURRENCY_TRANSFER_SUCCESS",
    currentHouseInfoRecieved = "CURRENT_HOUSE_INFO_RECIEVED",
    currentHouseInfoUpdated = "CURRENT_HOUSE_INFO_UPDATED",
    currentSpellCastChanged = "CURRENT_SPELL_CAST_CHANGED",
    cursorChanged = "CURSOR_CHANGED",
    cvarUpdate = "CVAR_UPDATE",
    dailyResetInstanceWelcome = "DAILY_RESET_INSTANCE_WELCOME",
    damageMeterCombatSessionUpdated = "DAMAGE_METER_COMBAT_SESSION_UPDATED",
    damageMeterCurrentSessionUpdated = "DAMAGE_METER_CURRENT_SESSION_UPDATED",
    damageMeterReset = "DAMAGE_METER_RESET",
    declineNeighborhoodInvitationResponse = "DECLINE_NEIGHBORHOOD_INVITATION_RESPONSE",
    deleteItemConfirm = "DELETE_ITEM_CONFIRM",
    delveAssistAction = "DELVE_ASSIST_ACTION",
    delvesAccountDataElementChanged = "DELVES_ACCOUNT_DATA_ELEMENT_CHANGED",
    disableDeclineGuildInvite = "DISABLE_DECLINE_GUILD_INVITE",
    disableLowLevelRaid = "DISABLE_LOW_LEVEL_RAID",
    disableTaxiBenchmark = "DISABLE_TAXI_BENCHMARK",
    disableXpGain = "DISABLE_XP_GAIN",
    discordGuildAchievement = "DISCORD_GUILD_ACHIEVEMENT",
    discordGuildLobbyUpdate = "DISCORD_GUILD_LOBBY_UPDATE",
    discordGuildSettingsUpdate = "DISCORD_GUILD_SETTINGS_UPDATE",
    discordLinkUpdate = "DISCORD_LINK_UPDATE",
    discordServerListUpdate = "DISCORD_SERVER_LIST_UPDATE",
    discordStatusUpdate = "DISCORD_STATUS_UPDATE",
    displayEventToastLink = "DISPLAY_EVENT_TOAST_LINK",
    displayEventToasts = "DISPLAY_EVENT_TOASTS",
    displaySizeChanged = "DISPLAY_SIZE_CHANGED",
    duelFinished = "DUEL_FINISHED",
    duelInbounds = "DUEL_INBOUNDS",
    duelOutofbounds = "DUEL_OUTOFBOUNDS",
    duelRequested = "DUEL_REQUESTED",
    duelToTheDeathRequested = "DUEL_TO_THE_DEATH_REQUESTED",
    dyeColorCategoryUpdated = "DYE_COLOR_CATEGORY_UPDATED",
    dyeColorUpdated = "DYE_COLOR_UPDATED",
    dynamicGossipPoiUpdated = "DYNAMIC_GOSSIP_POI_UPDATED",
    eclipseDirectionChange = "ECLIPSE_DIRECTION_CHANGE",
    editModeLayoutsUpdated = "EDIT_MODE_LAYOUTS_UPDATED",
    ejDifficultyUpdate = "EJ_DIFFICULTY_UPDATE",
    ejLootDataRecieved = "EJ_LOOT_DATA_RECIEVED",
    enableDeclineGuildInvite = "ENABLE_DECLINE_GUILD_INVITE",
    enableLowLevelRaid = "ENABLE_LOW_LEVEL_RAID",
    enableTaxiBenchmark = "ENABLE_TAXI_BENCHMARK",
    enableXpGain = "ENABLE_XP_GAIN",
    enchantSpellCompleted = "ENCHANT_SPELL_COMPLETED",
    enchantSpellSelected = "ENCHANT_SPELL_SELECTED",
    encounterEnd = "ENCOUNTER_END",
    encounterLootReceived = "ENCOUNTER_LOOT_RECEIVED",
    encounterStart = "ENCOUNTER_START",
    encounterStateChanged = "ENCOUNTER_STATE_CHANGED",
    encounterTimelineEventAdded = "ENCOUNTER_TIMELINE_EVENT_ADDED",
    encounterTimelineEventBlockStateChanged = "ENCOUNTER_TIMELINE_EVENT_BLOCK_STATE_CHANGED",
    encounterTimelineEventColorChanged = "ENCOUNTER_TIMELINE_EVENT_COLOR_CHANGED",
    encounterTimelineEventHighlight = "ENCOUNTER_TIMELINE_EVENT_HIGHLIGHT",
    encounterTimelineEventRemoved = "ENCOUNTER_TIMELINE_EVENT_REMOVED",
    encounterTimelineEventStateChanged = "ENCOUNTER_TIMELINE_EVENT_STATE_CHANGED",
    encounterTimelineEventTrackChanged = "ENCOUNTER_TIMELINE_EVENT_TRACK_CHANGED",
    encounterTimelineLayoutUpdated = "ENCOUNTER_TIMELINE_LAYOUT_UPDATED",
    encounterTimelineStateUpdated = "ENCOUNTER_TIMELINE_STATE_UPDATED",
    encounterTimelineViewActivated = "ENCOUNTER_TIMELINE_VIEW_ACTIVATED",
    encounterTimelineViewDeactivated = "ENCOUNTER_TIMELINE_VIEW_DEACTIVATED",
    encounterWarning = "ENCOUNTER_WARNING",
    endBoundTradeable = "END_BOUND_TRADEABLE",
    enteredDifferentInstanceFromParty = "ENTERED_DIFFERENT_INSTANCE_FROM_PARTY",
    entitlementDelivered = "ENTITLEMENT_DELIVERED",
    equipBindConfirm = "EQUIP_BIND_CONFIRM",
    equipBindRefundableConfirm = "EQUIP_BIND_REFUNDABLE_CONFIRM",
    equipBindTradeableConfirm = "EQUIP_BIND_TRADEABLE_CONFIRM",
    equipmentSetsChanged = "EQUIPMENT_SETS_CHANGED",
    equipmentSwapFinished = "EQUIPMENT_SWAP_FINISHED",
    equipmentSwapPending = "EQUIPMENT_SWAP_PENDING",
    eventRealmQueuesUpdated = "EVENT_REALM_QUEUES_UPDATED",
    eventSchedulerUpdate = "EVENT_SCHEDULER_UPDATE",
    expandBagBarChanged = "EXPAND_BAG_BAR_CHANGED",
    externalEventLaunchUrlFailed = "EXTERNAL_EVENT_LAUNCH_URL_FAILED",
    extraBrowseInfoReceived = "EXTRA_BROWSE_INFO_RECEIVED",
    factionStandingChanged = "FACTION_STANDING_CHANGED",
    firstFrameRendered = "FIRST_FRAME_RENDERED",
    fogOfWarUpdated = "FOG_OF_WAR_UPDATED",
    forbiddenNamePlateCreated = "FORBIDDEN_NAME_PLATE_CREATED",
    forbiddenNamePlateUnitAdded = "FORBIDDEN_NAME_PLATE_UNIT_ADDED",
    forbiddenNamePlateUnitRemoved = "FORBIDDEN_NAME_PLATE_UNIT_REMOVED",
    forceRefreshHouseFinder = "FORCE_REFRESH_HOUSE_FINDER",
    frameManagerUpdateAll = "FRAME_MANAGER_UPDATE_ALL",
    frameManagerUpdateFrame = "FRAME_MANAGER_UPDATE_FRAME",
    friendlistUpdate = "FRIENDLIST_UPDATE",
    fullscreenBrowserSpinnerHide = "FULLSCREEN_BROWSER_SPINNER_HIDE",
    fullscreenBrowserSpinnerShow = "FULLSCREEN_BROWSER_SPINNER_SHOW",
    gameModeDisplayInfoUpdated = "GAME_MODE_DISPLAY_INFO_UPDATED",
    gameModeDisplayModeToggleDisabled = "GAME_MODE_DISPLAY_MODE_TOGGLE_DISABLED",
    gamePadActiveChanged = "GAME_PAD_ACTIVE_CHANGED",
    gamePadConfigsChanged = "GAME_PAD_CONFIGS_CHANGED",
    gamePadConnected = "GAME_PAD_CONNECTED",
    gamePadDisconnected = "GAME_PAD_DISCONNECTED",
    gamePadPowerChanged = "GAME_PAD_POWER_CHANGED",
    garrisonArchitectClosed = "GARRISON_ARCHITECT_CLOSED",
    garrisonArchitectOpened = "GARRISON_ARCHITECT_OPENED",
    garrisonBuildingActivatable = "GARRISON_BUILDING_ACTIVATABLE",
    garrisonBuildingActivated = "GARRISON_BUILDING_ACTIVATED",
    garrisonBuildingError = "GARRISON_BUILDING_ERROR",
    garrisonBuildingListUpdate = "GARRISON_BUILDING_LIST_UPDATE",
    garrisonBuildingPlaced = "GARRISON_BUILDING_PLACED",
    garrisonBuildingRemoved = "GARRISON_BUILDING_REMOVED",
    garrisonBuildingUpdate = "GARRISON_BUILDING_UPDATE",
    garrisonFollowerAdded = "GARRISON_FOLLOWER_ADDED",
    garrisonFollowerCategoriesUpdated = "GARRISON_FOLLOWER_CATEGORIES_UPDATED",
    garrisonFollowerDurabilityChanged = "GARRISON_FOLLOWER_DURABILITY_CHANGED",
    garrisonFollowerHealed = "GARRISON_FOLLOWER_HEALED",
    garrisonFollowerListUpdate = "GARRISON_FOLLOWER_LIST_UPDATE",
    garrisonFollowerRemoved = "GARRISON_FOLLOWER_REMOVED",
    garrisonFollowerUpgraded = "GARRISON_FOLLOWER_UPGRADED",
    garrisonFollowerXpChanged = "GARRISON_FOLLOWER_XP_CHANGED",
    garrisonHideLandingPage = "GARRISON_HIDE_LANDING_PAGE",
    garrisonInvasionAvailable = "GARRISON_INVASION_AVAILABLE",
    garrisonInvasionUnavailable = "GARRISON_INVASION_UNAVAILABLE",
    garrisonLandingpageShipments = "GARRISON_LANDINGPAGE_SHIPMENTS",
    garrisonMissionAreaBonusAdded = "GARRISON_MISSION_AREA_BONUS_ADDED",
    garrisonMissionBonusRollComplete = "GARRISON_MISSION_BONUS_ROLL_COMPLETE",
    garrisonMissionBonusRollLoot = "GARRISON_MISSION_BONUS_ROLL_LOOT",
    garrisonMissionCompleteResponse = "GARRISON_MISSION_COMPLETE_RESPONSE",
    garrisonMissionFinished = "GARRISON_MISSION_FINISHED",
    garrisonMissionListUpdate = "GARRISON_MISSION_LIST_UPDATE",
    garrisonMissionNpcClosed = "GARRISON_MISSION_NPC_CLOSED",
    garrisonMissionNpcOpened = "GARRISON_MISSION_NPC_OPENED",
    garrisonMissionRewardInfo = "GARRISON_MISSION_REWARD_INFO",
    garrisonMissionStarted = "GARRISON_MISSION_STARTED",
    garrisonMonumentCloseUi = "GARRISON_MONUMENT_CLOSE_UI",
    garrisonMonumentListLoaded = "GARRISON_MONUMENT_LIST_LOADED",
    garrisonMonumentReplaced = "GARRISON_MONUMENT_REPLACED",
    garrisonMonumentSelectedTrophyIdLoaded = "GARRISON_MONUMENT_SELECTED_TROPHY_ID_LOADED",
    garrisonMonumentShowUi = "GARRISON_MONUMENT_SHOW_UI",
    garrisonRandomMissionAdded = "GARRISON_RANDOM_MISSION_ADDED",
    garrisonRecallPortalLastUsedTime = "GARRISON_RECALL_PORTAL_LAST_USED_TIME",
    garrisonRecallPortalUsed = "GARRISON_RECALL_PORTAL_USED",
    garrisonRecruitFollowerResult = "GARRISON_RECRUIT_FOLLOWER_RESULT",
    garrisonRecruitmentFollowersGenerated = "GARRISON_RECRUITMENT_FOLLOWERS_GENERATED",
    garrisonRecruitmentNpcClosed = "GARRISON_RECRUITMENT_NPC_CLOSED",
    garrisonRecruitmentNpcOpened = "GARRISON_RECRUITMENT_NPC_OPENED",
    garrisonRecruitmentReady = "GARRISON_RECRUITMENT_READY",
    garrisonShipmentReceived = "GARRISON_SHIPMENT_RECEIVED",
    garrisonShipyardNpcClosed = "GARRISON_SHIPYARD_NPC_CLOSED",
    garrisonShipyardNpcOpened = "GARRISON_SHIPYARD_NPC_OPENED",
    garrisonShowLandingPage = "GARRISON_SHOW_LANDING_PAGE",
    garrisonSpecGroupUpdated = "GARRISON_SPEC_GROUP_UPDATED",
    garrisonSpecGroupsCleared = "GARRISON_SPEC_GROUPS_CLEARED",
    garrisonTalentComplete = "GARRISON_TALENT_COMPLETE",
    garrisonTalentEventUpdate = "GARRISON_TALENT_EVENT_UPDATE",
    garrisonTalentNpcClosed = "GARRISON_TALENT_NPC_CLOSED",
    garrisonTalentNpcOpened = "GARRISON_TALENT_NPC_OPENED",
    garrisonTalentResearchStarted = "GARRISON_TALENT_RESEARCH_STARTED",
    garrisonTalentUnlocksResult = "GARRISON_TALENT_UNLOCKS_RESULT",
    garrisonTalentUpdate = "GARRISON_TALENT_UPDATE",
    garrisonTradeskillNpcClosed = "GARRISON_TRADESKILL_NPC_CLOSED",
    garrisonUpdate = "GARRISON_UPDATE",
    garrisonUpgradeableResult = "GARRISON_UPGRADEABLE_RESULT",
    garrisonUsePartyGarrisonChanged = "GARRISON_USE_PARTY_GARRISON_CHANGED",
    gdfSimComplete = "GDF_SIM_COMPLETE",
    genericError = "GENERIC_ERROR",
    genericWidgetDisplayShow = "GENERIC_WIDGET_DISPLAY_SHOW",
    getItemInfoReceived = "GET_ITEM_INFO_RECEIVED",
    globalMouseDown = "GLOBAL_MOUSE_DOWN",
    globalMouseUp = "GLOBAL_MOUSE_UP",
    glueScreenshotFailed = "GLUE_SCREENSHOT_FAILED",
    glueScreenshotStarted = "GLUE_SCREENSHOT_STARTED",
    glueScreenshotSucceeded = "GLUE_SCREENSHOT_SUCCEEDED",
    gmPlayerInfo = "GM_PLAYER_INFO",
    gossipClosed = "GOSSIP_CLOSED",
    gossipConfirm = "GOSSIP_CONFIRM",
    gossipConfirmCancel = "GOSSIP_CONFIRM_CANCEL",
    gossipEnterCode = "GOSSIP_ENTER_CODE",
    gossipOptionsRefreshed = "GOSSIP_OPTIONS_REFRESHED",
    gossipShow = "GOSSIP_SHOW",
    groupBuffVisualAlertsChanged = "GROUP_BUFF_VISUAL_ALERTS_CHANGED",
    groupFormed = "GROUP_FORMED",
    groupInviteConfirmation = "GROUP_INVITE_CONFIRMATION",
    groupJoined = "GROUP_JOINED",
    groupLeft = "GROUP_LEFT",
    groupRosterUpdate = "GROUP_ROSTER_UPDATE",
    guildChallengeCompleted = "GUILD_CHALLENGE_COMPLETED",
    guildChallengeUpdated = "GUILD_CHALLENGE_UPDATED",
    guildEventLogUpdate = "GUILD_EVENT_LOG_UPDATE",
    guildInviteCancel = "GUILD_INVITE_CANCEL",
    guildInviteRequest = "GUILD_INVITE_REQUEST",
    guildMotd = "GUILD_MOTD",
    guildNewsUpdate = "GUILD_NEWS_UPDATE",
    guildPartyStateUpdated = "GUILD_PARTY_STATE_UPDATED",
    guildRanksUpdate = "GUILD_RANKS_UPDATE",
    guildRanksUpdateActivePlayer = "GUILD_RANKS_UPDATE_ACTIVE_PLAYER",
    guildRecipeKnownByMembers = "GUILD_RECIPE_KNOWN_BY_MEMBERS",
    guildRegistrarClosed = "GUILD_REGISTRAR_CLOSED",
    guildRegistrarShow = "GUILD_REGISTRAR_SHOW",
    guildRenameNameCheck = "GUILD_RENAME_NAME_CHECK",
    guildRenameRefundResult = "GUILD_RENAME_REFUND_RESULT",
    guildRenameRequired = "GUILD_RENAME_REQUIRED",
    guildRenameStatusUpdate = "GUILD_RENAME_STATUS_UPDATE",
    guildRewardsList = "GUILD_REWARDS_LIST",
    guildRewardsListUpdate = "GUILD_REWARDS_LIST_UPDATE",
    guildRosterUpdate = "GUILD_ROSTER_UPDATE",
    guildTradeskillUpdate = "GUILD_TRADESKILL_UPDATE",
    guildbankItemLockChanged = "GUILDBANK_ITEM_LOCK_CHANGED",
    guildbankTextChanged = "GUILDBANK_TEXT_CHANGED",
    guildbankUpdateMoney = "GUILDBANK_UPDATE_MONEY",
    guildbankUpdateTabs = "GUILDBANK_UPDATE_TABS",
    guildbankUpdateText = "GUILDBANK_UPDATE_TEXT",
    guildbankUpdateWithdrawmoney = "GUILDBANK_UPDATE_WITHDRAWMONEY",
    guildbankbagslotsChanged = "GUILDBANKBAGSLOTS_CHANGED",
    guildbankframeClosed = "GUILDBANKFRAME_CLOSED",
    guildbankframeOpened = "GUILDBANKFRAME_OPENED",
    guildbanklogUpdate = "GUILDBANKLOG_UPDATE",
    guildtabardUpdate = "GUILDTABARD_UPDATE",
    gxRestarted = "GX_RESTARTED",
    handleUIAction = "HANDLE_UI_ACTION",
    hardcoreDeaths = "HARDCORE_DEATHS",
    hearthstoneBound = "HEARTHSTONE_BOUND",
    heirloomUpgradeTargetingChanged = "HEIRLOOM_UPGRADE_TARGETING_CHANGED",
    heirloomsUpdated = "HEIRLOOMS_UPDATED",
    hiddenGroupBuffsChanged = "HIDDEN_GROUP_BUFFS_CHANGED",
    hideHyperlinkTooltip = "HIDE_HYPERLINK_TOOLTIP",
    hideSubtitle = "HIDE_SUBTITLE",
    honorLevelUpdate = "HONOR_LEVEL_UPDATE",
    honorXpUpdate = "HONOR_XP_UPDATE",
    houseDecorAddedToChest = "HOUSE_DECOR_ADDED_TO_CHEST",
    houseEditorAvailabilityChanged = "HOUSE_EDITOR_AVAILABILITY_CHANGED",
    houseEditorModeChangeFailure = "HOUSE_EDITOR_MODE_CHANGE_FAILURE",
    houseEditorModeChanged = "HOUSE_EDITOR_MODE_CHANGED",
    houseExteriorDecorHiddenChanged = "HOUSE_EXTERIOR_DECOR_HIDDEN_CHANGED",
    houseExteriorPositionFailure = "HOUSE_EXTERIOR_POSITION_FAILURE",
    houseExteriorPositionSuccess = "HOUSE_EXTERIOR_POSITION_SUCCESS",
    houseExteriorTypeUnlocked = "HOUSE_EXTERIOR_TYPE_UNLOCKED",
    houseFinderNeighborhoodDataRecieved = "HOUSE_FINDER_NEIGHBORHOOD_DATA_RECIEVED",
    houseInfoUpdated = "HOUSE_INFO_UPDATED",
    houseLevelChanged = "HOUSE_LEVEL_CHANGED",
    houseLevelFavorUpdated = "HOUSE_LEVEL_FAVOR_UPDATED",
    housePlotEntered = "HOUSE_PLOT_ENTERED",
    housePlotExited = "HOUSE_PLOT_EXITED",
    houseReservationResponseRecieved = "HOUSE_RESERVATION_RESPONSE_RECIEVED",
    houseResetCompleted = "HOUSE_RESET_COMPLETED",
    houseResetFailed = "HOUSE_RESET_FAILED",
    housingBasicModeHoveredTargetChanged = "HOUSING_BASIC_MODE_HOVERED_TARGET_CHANGED",
    housingBasicModePlacementFlagsUpdated = "HOUSING_BASIC_MODE_PLACEMENT_FLAGS_UPDATED",
    housingBasicModeSelectedTargetChanged = "HOUSING_BASIC_MODE_SELECTED_TARGET_CHANGED",
    housingBlueprintCollectionFailure = "HOUSING_BLUEPRINT_COLLECTION_FAILURE",
    housingBlueprintCollectionReceived = "HOUSING_BLUEPRINT_COLLECTION_RECEIVED",
    housingBlueprintContentsFailure = "HOUSING_BLUEPRINT_CONTENTS_FAILURE",
    housingBlueprintContentsReceived = "HOUSING_BLUEPRINT_CONTENTS_RECEIVED",
    housingBlueprintDeleteFailure = "HOUSING_BLUEPRINT_DELETE_FAILURE",
    housingBlueprintDeleteSuccess = "HOUSING_BLUEPRINT_DELETE_SUCCESS",
    housingBlueprintExportFailure = "HOUSING_BLUEPRINT_EXPORT_FAILURE",
    housingBlueprintExportSuccess = "HOUSING_BLUEPRINT_EXPORT_SUCCESS",
    housingBlueprintImportFailure = "HOUSING_BLUEPRINT_IMPORT_FAILURE",
    housingBlueprintImportStarted = "HOUSING_BLUEPRINT_IMPORT_STARTED",
    housingBlueprintImportSuccess = "HOUSING_BLUEPRINT_IMPORT_SUCCESS",
    housingBlueprintRenameFailure = "HOUSING_BLUEPRINT_RENAME_FAILURE",
    housingBlueprintRenameSuccess = "HOUSING_BLUEPRINT_RENAME_SUCCESS",
    housingBlueprintsAvailabilityChanged = "HOUSING_BLUEPRINTS_AVAILABILITY_CHANGED",
    housingCatalogCategoryUpdated = "HOUSING_CATALOG_CATEGORY_UPDATED",
    housingCatalogSubcategoryUpdated = "HOUSING_CATALOG_SUBCATEGORY_UPDATED",
    housingCleanupModeHoveredTargetChanged = "HOUSING_CLEANUP_MODE_HOVERED_TARGET_CHANGED",
    housingCleanupModeTargetSelected = "HOUSING_CLEANUP_MODE_TARGET_SELECTED",
    housingCoreFixtureChanged = "HOUSING_CORE_FIXTURE_CHANGED",
    housingCustomizeModeHoveredTargetChanged = "HOUSING_CUSTOMIZE_MODE_HOVERED_TARGET_CHANGED",
    housingCustomizeModeSelectedTargetChanged = "HOUSING_CUSTOMIZE_MODE_SELECTED_TARGET_CHANGED",
    housingDecorAddToPreviewList = "HOUSING_DECOR_ADD_TO_PREVIEW_LIST",
    housingDecorCustomizationChanged = "HOUSING_DECOR_CUSTOMIZATION_CHANGED",
    housingDecorDyeFailure = "HOUSING_DECOR_DYE_FAILURE",
    housingDecorFreePlaceStatusChanged = "HOUSING_DECOR_FREE_PLACE_STATUS_CHANGED",
    housingDecorGridSnapOccurred = "HOUSING_DECOR_GRID_SNAP_OCCURRED",
    housingDecorGridSnapStatusChanged = "HOUSING_DECOR_GRID_SNAP_STATUS_CHANGED",
    housingDecorGridVisibilityStatusChanged = "HOUSING_DECOR_GRID_VISIBILITY_STATUS_CHANGED",
    housingDecorPlaceFailure = "HOUSING_DECOR_PLACE_FAILURE",
    housingDecorPlaceSuccess = "HOUSING_DECOR_PLACE_SUCCESS",
    housingDecorPrecisionManipulationEvent = "HOUSING_DECOR_PRECISION_MANIPULATION_EVENT",
    housingDecorPrecisionManipulationStatusChanged = "HOUSING_DECOR_PRECISION_MANIPULATION_STATUS_CHANGED",
    housingDecorPrecisionSubmodeChanged = "HOUSING_DECOR_PRECISION_SUBMODE_CHANGED",
    housingDecorPreviewListRemoveFromWorld = "HOUSING_DECOR_PREVIEW_LIST_REMOVE_FROM_WORLD",
    housingDecorPreviewListUpdated = "HOUSING_DECOR_PREVIEW_LIST_UPDATED",
    housingDecorPreviewStateChanged = "HOUSING_DECOR_PREVIEW_STATE_CHANGED",
    housingDecorRemoved = "HOUSING_DECOR_REMOVED",
    housingDecorSelectResponse = "HOUSING_DECOR_SELECT_RESPONSE",
    housingExpertModeHoveredTargetChanged = "HOUSING_EXPERT_MODE_HOVERED_TARGET_CHANGED",
    housingExpertModePlacementFlagsUpdated = "HOUSING_EXPERT_MODE_PLACEMENT_FLAGS_UPDATED",
    housingExpertModeSelectedTargetChanged = "HOUSING_EXPERT_MODE_SELECTED_TARGET_CHANGED",
    housingFixtureHoverChanged = "HOUSING_FIXTURE_HOVER_CHANGED",
    housingFixturePointFrameAdded = "HOUSING_FIXTURE_POINT_FRAME_ADDED",
    housingFixturePointFrameReleased = "HOUSING_FIXTURE_POINT_FRAME_RELEASED",
    housingFixturePointFramesReleased = "HOUSING_FIXTURE_POINT_FRAMES_RELEASED",
    housingFixturePointSelectionChanged = "HOUSING_FIXTURE_POINT_SELECTION_CHANGED",
    housingFixtureUnlocked = "HOUSING_FIXTURE_UNLOCKED",
    housingInspectModeDecorHoveredChanged = "HOUSING_INSPECT_MODE_DECOR_HOVERED_CHANGED",
    housingInspectModeStateUpdated = "HOUSING_INSPECT_MODE_STATE_UPDATED",
    housingLayoutDoorSelected = "HOUSING_LAYOUT_DOOR_SELECTED",
    housingLayoutDoorSelectionChanged = "HOUSING_LAYOUT_DOOR_SELECTION_CHANGED",
    housingLayoutDragTargetChanged = "HOUSING_LAYOUT_DRAG_TARGET_CHANGED",
    housingLayoutFloorplanSelectionChanged = "HOUSING_LAYOUT_FLOORPLAN_SELECTION_CHANGED",
    housingLayoutOccupiedFloorRangeChanged = "HOUSING_LAYOUT_OCCUPIED_FLOOR_RANGE_CHANGED",
    housingLayoutPinFrameAdded = "HOUSING_LAYOUT_PIN_FRAME_ADDED",
    housingLayoutPinFrameReleased = "HOUSING_LAYOUT_PIN_FRAME_RELEASED",
    housingLayoutPinFramesReleased = "HOUSING_LAYOUT_PIN_FRAMES_RELEASED",
    housingLayoutRoomComponentThemeSetChanged = "HOUSING_LAYOUT_ROOM_COMPONENT_THEME_SET_CHANGED",
    housingLayoutRoomMoveInvalid = "HOUSING_LAYOUT_ROOM_MOVE_INVALID",
    housingLayoutRoomMoved = "HOUSING_LAYOUT_ROOM_MOVED",
    housingLayoutRoomReceived = "HOUSING_LAYOUT_ROOM_RECEIVED",
    housingLayoutRoomRemoved = "HOUSING_LAYOUT_ROOM_REMOVED",
    housingLayoutRoomReturned = "HOUSING_LAYOUT_ROOM_RETURNED",
    housingLayoutRoomSelectionChanged = "HOUSING_LAYOUT_ROOM_SELECTION_CHANGED",
    housingLayoutRoomSnapped = "HOUSING_LAYOUT_ROOM_SNAPPED",
    housingLayoutViewedFloorChanged = "HOUSING_LAYOUT_VIEWED_FLOOR_CHANGED",
    housingMarketAvailabilityUpdated = "HOUSING_MARKET_AVAILABILITY_UPDATED",
    housingNewDecorPlaceComplete = "HOUSING_NEW_DECOR_PLACE_COMPLETE",
    housingNumDecorPlacedChanged = "HOUSING_NUM_DECOR_PLACED_CHANGED",
    housingRefundListUpdated = "HOUSING_REFUND_LIST_UPDATED",
    housingRoomComponentCustomizationChangeFailed = "HOUSING_ROOM_COMPONENT_CUSTOMIZATION_CHANGE_FAILED",
    housingRoomComponentCustomizationChanged = "HOUSING_ROOM_COMPONENT_CUSTOMIZATION_CHANGED",
    housingServicesAvailabilityUpdated = "HOUSING_SERVICES_AVAILABILITY_UPDATED",
    housingSetExteriorHouseSizeResponse = "HOUSING_SET_EXTERIOR_HOUSE_SIZE_RESPONSE",
    housingSetExteriorHouseTypeResponse = "HOUSING_SET_EXTERIOR_HOUSE_TYPE_RESPONSE",
    housingSetFixtureResponse = "HOUSING_SET_FIXTURE_RESPONSE",
    housingStorageEntryUpdated = "HOUSING_STORAGE_ENTRY_UPDATED",
    housingStorageUpdated = "HOUSING_STORAGE_UPDATED",
    ignoreNeighborhoodResponse = "IGNORE_NEIGHBORHOOD_RESPONSE",
    ignorelistUpdate = "IGNORELIST_UPDATE",
    immersiveInteractionBegin = "IMMERSIVE_INTERACTION_BEGIN",
    immersiveInteractionEnd = "IMMERSIVE_INTERACTION_END",
    incomingResurrectChanged = "INCOMING_RESURRECT_CHANGED",
    incomingSummonChanged = "INCOMING_SUMMON_CHANGED",
    initialClubsLoaded = "INITIAL_CLUBS_LOADED",
    initialHotfixesApplied = "INITIAL_HOTFIXES_APPLIED",
    initiativeActivityLogUpdated = "INITIATIVE_ACTIVITY_LOG_UPDATED",
    initiativeCompleted = "INITIATIVE_COMPLETED",
    initiativeTaskCompleted = "INITIATIVE_TASK_COMPLETED",
    initiativeTasksTrackedListChanged = "INITIATIVE_TASKS_TRACKED_LIST_CHANGED",
    initiativeTasksTrackedUpdated = "INITIATIVE_TASKS_TRACKED_UPDATED",
    inspectAchievementReady = "INSPECT_ACHIEVEMENT_READY",
    inspectHonorUpdate = "INSPECT_HONOR_UPDATE",
    inspectReady = "INSPECT_READY",
    instanceAbandonVoteFinished = "INSTANCE_ABANDON_VOTE_FINISHED",
    instanceAbandonVoteStarted = "INSTANCE_ABANDON_VOTE_STARTED",
    instanceAbandonVoteUpdated = "INSTANCE_ABANDON_VOTE_UPDATED",
    instanceBootStart = "INSTANCE_BOOT_START",
    instanceBootStop = "INSTANCE_BOOT_STOP",
    instanceEncounterAddTimer = "INSTANCE_ENCOUNTER_ADD_TIMER",
    instanceEncounterEngageUnit = "INSTANCE_ENCOUNTER_ENGAGE_UNIT",
    instanceEncounterObjectiveComplete = "INSTANCE_ENCOUNTER_OBJECTIVE_COMPLETE",
    instanceEncounterObjectiveStart = "INSTANCE_ENCOUNTER_OBJECTIVE_START",
    instanceEncounterObjectiveUpdate = "INSTANCE_ENCOUNTER_OBJECTIVE_UPDATE",
    instanceGroupSizeChanged = "INSTANCE_GROUP_SIZE_CHANGED",
    instanceLeaverStatusChanged = "INSTANCE_LEAVER_STATUS_CHANGED",
    instanceLockStart = "INSTANCE_LOCK_START",
    instanceLockStop = "INSTANCE_LOCK_STOP",
    instanceLockWarning = "INSTANCE_LOCK_WARNING",
    instanceResetWarning = "INSTANCE_RESET_WARNING",
    inventorySearchUpdate = "INVENTORY_SEARCH_UPDATE",
    inviteToPartyConfirmation = "INVITE_TO_PARTY_CONFIRMATION",
    inviteTravelPassConfirmation = "INVITE_TRAVEL_PASS_CONFIRMATION",
    islandAzeriteGain = "ISLAND_AZERITE_GAIN",
    islandCompleted = "ISLAND_COMPLETED",
    islandsQueueClose = "ISLANDS_QUEUE_CLOSE",
    islandsQueueOpen = "ISLANDS_QUEUE_OPEN",
    itemChanged = "ITEM_CHANGED",
    itemConversionDataReady = "ITEM_CONVERSION_DATA_READY",
    itemCountChanged = "ITEM_COUNT_CHANGED",
    itemDataLoadResult = "ITEM_DATA_LOAD_RESULT",
    itemInteractionChargeInfoUpdated = "ITEM_INTERACTION_CHARGE_INFO_UPDATED",
    itemInteractionItemSelectionUpdated = "ITEM_INTERACTION_ITEM_SELECTION_UPDATED",
    itemKeyItemInfoReceived = "ITEM_KEY_ITEM_INFO_RECEIVED",
    itemLockChanged = "ITEM_LOCK_CHANGED",
    itemLocked = "ITEM_LOCKED",
    itemPurchased = "ITEM_PURCHASED",
    itemPush = "ITEM_PUSH",
    itemRestorationButtonStatus = "ITEM_RESTORATION_BUTTON_STATUS",
    itemSearchResultsAdded = "ITEM_SEARCH_RESULTS_ADDED",
    itemSearchResultsUpdated = "ITEM_SEARCH_RESULTS_UPDATED",
    itemTextBegin = "ITEM_TEXT_BEGIN",
    itemTextClosed = "ITEM_TEXT_CLOSED",
    itemTextReady = "ITEM_TEXT_READY",
    itemTextTranslation = "ITEM_TEXT_TRANSLATION",
    itemUnlocked = "ITEM_UNLOCKED",
    itemUpgradeFailed = "ITEM_UPGRADE_FAILED",
    itemUpgradeMasterSetItem = "ITEM_UPGRADE_MASTER_SET_ITEM",
    itemUpgradeMasterUpdate = "ITEM_UPGRADE_MASTER_UPDATE",
    jailersTowerLevelUpdate = "JAILERS_TOWER_LEVEL_UPDATE",
    knownTitlesUpdate = "KNOWN_TITLES_UPDATE",
    languageListChanged = "LANGUAGE_LIST_CHANGED",
    learnedSpellInSkillLine = "LEARNED_SPELL_IN_SKILL_LINE",
    leavePartyConfirmation = "LEAVE_PARTY_CONFIRMATION",
    leavingTutorialArea = "LEAVING_TUTORIAL_AREA",
    legacyFriendSystemStatusUpdated = "LEGACY_FRIEND_SYSTEM_STATUS_UPDATED",
    legacyLootRulesChanged = "LEGACY_LOOT_RULES_CHANGED",
    letRecentAlliesSeeLocationSettingUpdated = "LET_RECENT_ALLIES_SEE_LOCATION_SETTING_UPDATED",
    lfgBootProposalUpdate = "LFG_BOOT_PROPOSAL_UPDATE",
    lfgCompletionReward = "LFG_COMPLETION_REWARD",
    lfgCooldownsUpdated = "LFG_COOLDOWNS_UPDATED",
    lfgEnabledStateChanged = "LFG_ENABLED_STATE_CHANGED",
    lfgGroupDelistedLeadershipChange = "LFG_GROUP_DELISTED_LEADERSHIP_CHANGE",
    lfgInvalidErrorMessage = "LFG_INVALID_ERROR_MESSAGE",
    lfgListActiveEntryUpdate = "LFG_LIST_ACTIVE_ENTRY_UPDATE",
    lfgListApplicantListUpdated = "LFG_LIST_APPLICANT_LIST_UPDATED",
    lfgListApplicantUpdated = "LFG_LIST_APPLICANT_UPDATED",
    lfgListApplicationStatusUpdated = "LFG_LIST_APPLICATION_STATUS_UPDATED",
    lfgListAvailabilityUpdate = "LFG_LIST_AVAILABILITY_UPDATE",
    lfgListCensoredActiveEntryUpdate = "LFG_LIST_CENSORED_ACTIVE_ENTRY_UPDATE",
    lfgListEntryCreationFailed = "LFG_LIST_ENTRY_CREATION_FAILED",
    lfgListEntryExpiredTimeout = "LFG_LIST_ENTRY_EXPIRED_TIMEOUT",
    lfgListEntryExpiredTooManyPlayers = "LFG_LIST_ENTRY_EXPIRED_TOO_MANY_PLAYERS",
    lfgListJoinedGroup = "LFG_LIST_JOINED_GROUP",
    lfgListRevealedCensoredActiveEntry = "LFG_LIST_REVEALED_CENSORED_ACTIVE_ENTRY",
    lfgListSearchFailed = "LFG_LIST_SEARCH_FAILED",
    lfgListSearchResultUpdated = "LFG_LIST_SEARCH_RESULT_UPDATED",
    lfgListSearchResultsReceived = "LFG_LIST_SEARCH_RESULTS_RECEIVED",
    lfgListUpdateSearchResults = "LFG_LIST_UPDATE_SEARCH_RESULTS",
    lfgLockInfoReceived = "LFG_LOCK_INFO_RECEIVED",
    lfgOfferContinue = "LFG_OFFER_CONTINUE",
    lfgOpenFromGossip = "LFG_OPEN_FROM_GOSSIP",
    lfgProposalDone = "LFG_PROPOSAL_DONE",
    lfgProposalFailed = "LFG_PROPOSAL_FAILED",
    lfgProposalShow = "LFG_PROPOSAL_SHOW",
    lfgProposalSucceeded = "LFG_PROPOSAL_SUCCEEDED",
    lfgProposalUpdate = "LFG_PROPOSAL_UPDATE",
    lfgQueueStatusUpdate = "LFG_QUEUE_STATUS_UPDATE",
    lfgReadyCheckDeclined = "LFG_READY_CHECK_DECLINED",
    lfgReadyCheckHide = "LFG_READY_CHECK_HIDE",
    lfgReadyCheckPlayerIsReady = "LFG_READY_CHECK_PLAYER_IS_READY",
    lfgReadyCheckShow = "LFG_READY_CHECK_SHOW",
    lfgReadyCheckUpdate = "LFG_READY_CHECK_UPDATE",
    lfgRoleCheckDeclined = "LFG_ROLE_CHECK_DECLINED",
    lfgRoleCheckHide = "LFG_ROLE_CHECK_HIDE",
    lfgRoleCheckRoleChosen = "LFG_ROLE_CHECK_ROLE_CHOSEN",
    lfgRoleCheckShow = "LFG_ROLE_CHECK_SHOW",
    lfgRoleCheckUpdate = "LFG_ROLE_CHECK_UPDATE",
    lfgRoleUpdate = "LFG_ROLE_UPDATE",
    lfgUpdate = "LFG_UPDATE",
    lfgUpdateRandomInfo = "LFG_UPDATE_RANDOM_INFO",
    lifestealUpdate = "LIFESTEAL_UPDATE",
    loadingScreenDisabled = "LOADING_SCREEN_DISABLED",
    loadingScreenEnabled = "LOADING_SCREEN_ENABLED",
    lobbyMatchmakerQueueAbandoned = "LOBBY_MATCHMAKER_QUEUE_ABANDONED",
    lobbyMatchmakerQueueError = "LOBBY_MATCHMAKER_QUEUE_ERROR",
    lobbyMatchmakerQueueExpired = "LOBBY_MATCHMAKER_QUEUE_EXPIRED",
    lobbyMatchmakerQueuePopped = "LOBBY_MATCHMAKER_QUEUE_POPPED",
    lobbyMatchmakerQueueStatusUpdate = "LOBBY_MATCHMAKER_QUEUE_STATUS_UPDATE",
    locResult = "LOC_RESULT",
    localplayerPetRenamed = "LOCALPLAYER_PET_RENAMED",
    logoutCancel = "LOGOUT_CANCEL",
    lootBindConfirm = "LOOT_BIND_CONFIRM",
    lootClosed = "LOOT_CLOSED",
    lootHistoryClearHistory = "LOOT_HISTORY_CLEAR_HISTORY",
    lootHistoryGoToEncounter = "LOOT_HISTORY_GO_TO_ENCOUNTER",
    lootHistoryOneHundredRoll = "LOOT_HISTORY_ONE_HUNDRED_ROLL",
    lootHistoryUpdateDrop = "LOOT_HISTORY_UPDATE_DROP",
    lootHistoryUpdateEncounter = "LOOT_HISTORY_UPDATE_ENCOUNTER",
    lootItemAvailable = "LOOT_ITEM_AVAILABLE",
    lootItemRollWon = "LOOT_ITEM_ROLL_WON",
    lootJournalItemUpdate = "LOOT_JOURNAL_ITEM_UPDATE",
    lootOpened = "LOOT_OPENED",
    lootReady = "LOOT_READY",
    lootRollsComplete = "LOOT_ROLLS_COMPLETE",
    lootSlotChanged = "LOOT_SLOT_CHANGED",
    lootSlotCleared = "LOOT_SLOT_CLEARED",
    loreTextUpdatedCampaign = "LORE_TEXT_UPDATED_CAMPAIGN",
    lossOfControlAdded = "LOSS_OF_CONTROL_ADDED",
    lossOfControlCommentatorAdded = "LOSS_OF_CONTROL_COMMENTATOR_ADDED",
    lossOfControlCommentatorUpdate = "LOSS_OF_CONTROL_COMMENTATOR_UPDATE",
    lossOfControlUpdate = "LOSS_OF_CONTROL_UPDATE",
    luaWarning = "LUA_WARNING",
    macroActionBlocked = "MACRO_ACTION_BLOCKED",
    macroActionForbidden = "MACRO_ACTION_FORBIDDEN",
    mailClosed = "MAIL_CLOSED",
    mailFailed = "MAIL_FAILED",
    mailInboxUpdate = "MAIL_INBOX_UPDATE",
    mailLockSendItems = "MAIL_LOCK_SEND_ITEMS",
    mailSendInfoUpdate = "MAIL_SEND_INFO_UPDATE",
    mailSendSuccess = "MAIL_SEND_SUCCESS",
    mailShow = "MAIL_SHOW",
    mailSuccess = "MAIL_SUCCESS",
    mailUnlockSendItems = "MAIL_UNLOCK_SEND_ITEMS",
    mainSpecNeedRoll = "MAIN_SPEC_NEED_ROLL",
    majorFactionInteractionEnded = "MAJOR_FACTION_INTERACTION_ENDED",
    majorFactionInteractionStarted = "MAJOR_FACTION_INTERACTION_STARTED",
    majorFactionRenownLevelChanged = "MAJOR_FACTION_RENOWN_LEVEL_CHANGED",
    majorFactionUnlocked = "MAJOR_FACTION_UNLOCKED",
    mapExplorationUpdated = "MAP_EXPLORATION_UPDATED",
    masteryUpdate = "MASTERY_UPDATE",
    maxExpansionLevelUpdated = "MAX_EXPANSION_LEVEL_UPDATED",
    maxSpellStartRecoveryOffsetChanged = "MAX_SPELL_START_RECOVERY_OFFSET_CHANGED",
    mentorshipStatusChanged = "MENTORSHIP_STATUS_CHANGED",
    merchantClosed = "MERCHANT_CLOSED",
    merchantConfirmTradeTimerRemoval = "MERCHANT_CONFIRM_TRADE_TIMER_REMOVAL",
    merchantFilterItemUpdate = "MERCHANT_FILTER_ITEM_UPDATE",
    merchantShow = "MERCHANT_SHOW",
    merchantUpdate = "MERCHANT_UPDATE",
    minExpansionLevelUpdated = "MIN_EXPANSION_LEVEL_UPDATED",
    minimapPing = "MINIMAP_PING",
    minimapUpdateTracking = "MINIMAP_UPDATE_TRACKING",
    minimapUpdateZoom = "MINIMAP_UPDATE_ZOOM",
    mirrorTimerPause = "MIRROR_TIMER_PAUSE",
    mirrorTimerStart = "MIRROR_TIMER_START",
    mirrorTimerStop = "MIRROR_TIMER_STOP",
    modifierStateChanged = "MODIFIER_STATE_CHANGED",
    mountCursorClear = "MOUNT_CURSOR_CLEAR",
    mountEquipmentApplyResult = "MOUNT_EQUIPMENT_APPLY_RESULT",
    mountJournalSearchUpdated = "MOUNT_JOURNAL_SEARCH_UPDATED",
    mountJournalUsabilityChanged = "MOUNT_JOURNAL_USABILITY_CHANGED",
    moveOutReservationUpdated = "MOVE_OUT_RESERVATION_UPDATED",
    mutelistUpdate = "MUTELIST_UPDATE",
    mythicPlusCurrentAffixUpdate = "MYTHIC_PLUS_CURRENT_AFFIX_UPDATE",
    mythicPlusNewWeeklyRecord = "MYTHIC_PLUS_NEW_WEEKLY_RECORD",
    namePlateCreated = "NAME_PLATE_CREATED",
    namePlateUnitAdded = "NAME_PLATE_UNIT_ADDED",
    namePlateUnitBehindCameraChanged = "NAME_PLATE_UNIT_BEHIND_CAMERA_CHANGED",
    namePlateUnitRemoved = "NAME_PLATE_UNIT_REMOVED",
    navigationDestinationReached = "NAVIGATION_DESTINATION_REACHED",
    navigationFrameCreated = "NAVIGATION_FRAME_CREATED",
    navigationFrameDestroyed = "NAVIGATION_FRAME_DESTROYED",
    neighborhoodGuildSizeValidated = "NEIGHBORHOOD_GUILD_SIZE_VALIDATED",
    neighborhoodInfoUpdated = "NEIGHBORHOOD_INFO_UPDATED",
    neighborhoodInitiativeUpdated = "NEIGHBORHOOD_INITIATIVE_UPDATED",
    neighborhoodInviteResponse = "NEIGHBORHOOD_INVITE_RESPONSE",
    neighborhoodListUpdated = "NEIGHBORHOOD_LIST_UPDATED",
    neighborhoodMapDataUpdated = "NEIGHBORHOOD_MAP_DATA_UPDATED",
    neighborhoodNameUpdated = "NEIGHBORHOOD_NAME_UPDATED",
    neighborhoodNameValidated = "NEIGHBORHOOD_NAME_VALIDATED",
    neutralFactionSelectResult = "NEUTRAL_FACTION_SELECT_RESULT",
    newHousingItemAcquired = "NEW_HOUSING_ITEM_ACQUIRED",
    newMatchmakingPartyInvite = "NEW_MATCHMAKING_PARTY_INVITE",
    newMountAdded = "NEW_MOUNT_ADDED",
    newPetAdded = "NEW_PET_ADDED",
    newRecipeLearned = "NEW_RECIPE_LEARNED",
    newRuneforgePowerAdded = "NEW_RUNEFORGE_POWER_ADDED",
    newToyAdded = "NEW_TOY_ADDED",
    newWarbandSceneAdded = "NEW_WARBAND_SCENE_ADDED",
    newWmoChunk = "NEW_WMO_CHUNK",
    newcomerGraduation = "NEWCOMER_GRADUATION",
    notchedDisplayModeChanged = "NOTCHED_DISPLAY_MODE_CHANGED",
    notifyChatSuppressed = "NOTIFY_CHAT_SUPPRESSED",
    notifyPvpAfkResult = "NOTIFY_PVP_AFK_RESULT",
    notifyTurnStrafeChange = "NOTIFY_TURN_STRAFE_CHANGE",
    npeTutorialUpdate = "NPE_TUTORIAL_UPDATE",
    objectEnteredAOI = "OBJECT_ENTERED_AOI",
    objectLeftAOI = "OBJECT_LEFT_AOI",
    obliterumForgePendingItemChanged = "OBLITERUM_FORGE_PENDING_ITEM_CHANGED",
    openCharterConfirmationUI = "OPEN_CHARTER_CONFIRMATION_UI",
    openCreateCharterNeighborhoodUI = "OPEN_CREATE_CHARTER_NEIGHBORHOOD_UI",
    openCreateGuildNeighborhoodUI = "OPEN_CREATE_GUILD_NEIGHBORHOOD_UI",
    openMasterLootList = "OPEN_MASTER_LOOT_LIST",
    openNeighborhoodCharter = "OPEN_NEIGHBORHOOD_CHARTER",
    openNeighborhoodCharterSignatureRequest = "OPEN_NEIGHBORHOOD_CHARTER_SIGNATURE_REQUEST",
    openPlotCornerstone = "OPEN_PLOT_CORNERSTONE",
    openRecipeResponse = "OPEN_RECIPE_RESPONSE",
    openSplashScreen = "OPEN_SPLASH_SCREEN",
    openTabardFrame = "OPEN_TABARD_FRAME",
    ownedAuctionBidderInfoReceived = "OWNED_AUCTION_BIDDER_INFO_RECEIVED",
    ownedAuctionsUpdated = "OWNED_AUCTIONS_UPDATED",
    partyEligibilityForDelveTiersChanged = "PARTY_ELIGIBILITY_FOR_DELVE_TIERS_CHANGED",
    partyInviteCancel = "PARTY_INVITE_CANCEL",
    partyInviteRequest = "PARTY_INVITE_REQUEST",
    partyKill = "PARTY_KILL",
    partyLeaderChanged = "PARTY_LEADER_CHANGED",
    partyLfgRestricted = "PARTY_LFG_RESTRICTED",
    partyLootMethodChanged = "PARTY_LOOT_METHOD_CHANGED",
    partyMemberDisable = "PARTY_MEMBER_DISABLE",
    partyMemberEnable = "PARTY_MEMBER_ENABLE",
    pendingAzeriteEssenceChanged = "PENDING_AZERITE_ESSENCE_CHANGED",
    pendingNeighborhoodInvitesRecieved = "PENDING_NEIGHBORHOOD_INVITES_RECIEVED",
    perksActivitiesTrackedListChanged = "PERKS_ACTIVITIES_TRACKED_LIST_CHANGED",
    perksActivitiesTrackedUpdated = "PERKS_ACTIVITIES_TRACKED_UPDATED",
    perksActivitiesUpdated = "PERKS_ACTIVITIES_UPDATED",
    perksActivityCompleted = "PERKS_ACTIVITY_COMPLETED",
    perksProgramAddPendingShopItem = "PERKS_PROGRAM_ADD_PENDING_SHOP_ITEM",
    perksProgramClose = "PERKS_PROGRAM_CLOSE",
    perksProgramCurrencyAwarded = "PERKS_PROGRAM_CURRENCY_AWARDED",
    perksProgramCurrencyRefresh = "PERKS_PROGRAM_CURRENCY_REFRESH",
    perksProgramDataRefresh = "PERKS_PROGRAM_DATA_REFRESH",
    perksProgramDataSpecificItemRefresh = "PERKS_PROGRAM_DATA_SPECIFIC_ITEM_REFRESH",
    perksProgramDisabled = "PERKS_PROGRAM_DISABLED",
    perksProgramOpen = "PERKS_PROGRAM_OPEN",
    perksProgramPurchaseCartSuccess = "PERKS_PROGRAM_PURCHASE_CART_SUCCESS",
    perksProgramPurchaseSuccess = "PERKS_PROGRAM_PURCHASE_SUCCESS",
    perksProgramRefundSuccess = "PERKS_PROGRAM_REFUND_SUCCESS",
    perksProgramRemovePendingShopItem = "PERKS_PROGRAM_REMOVE_PENDING_SHOP_ITEM",
    perksProgramResultError = "PERKS_PROGRAM_RESULT_ERROR",
    perksProgramSetFrozenItem = "PERKS_PROGRAM_SET_FROZEN_ITEM",
    petAttackStart = "PET_ATTACK_START",
    petAttackStop = "PET_ATTACK_STOP",
    petBarHidegrid = "PET_BAR_HIDEGRID",
    petBarShowgrid = "PET_BAR_SHOWGRID",
    petBarUpdate = "PET_BAR_UPDATE",
    petBarUpdateCooldown = "PET_BAR_UPDATE_COOLDOWN",
    petBarUpdateUsable = "PET_BAR_UPDATE_USABLE",
    petBattleAbilityChanged = "PET_BATTLE_ABILITY_CHANGED",
    petBattleActionSelected = "PET_BATTLE_ACTION_SELECTED",
    petBattleAuraApplied = "PET_BATTLE_AURA_APPLIED",
    petBattleAuraCanceled = "PET_BATTLE_AURA_CANCELED",
    petBattleAuraChanged = "PET_BATTLE_AURA_CHANGED",
    petBattleCaptured = "PET_BATTLE_CAPTURED",
    petBattleClose = "PET_BATTLE_CLOSE",
    petBattleFinalRound = "PET_BATTLE_FINAL_ROUND",
    petBattleHealthChanged = "PET_BATTLE_HEALTH_CHANGED",
    petBattleLevelChanged = "PET_BATTLE_LEVEL_CHANGED",
    petBattleLootReceived = "PET_BATTLE_LOOT_RECEIVED",
    petBattleMaxHealthChanged = "PET_BATTLE_MAX_HEALTH_CHANGED",
    petBattleOpeningDone = "PET_BATTLE_OPENING_DONE",
    petBattleOpeningStart = "PET_BATTLE_OPENING_START",
    petBattleOver = "PET_BATTLE_OVER",
    petBattleOverrideAbility = "PET_BATTLE_OVERRIDE_ABILITY",
    petBattlePetChanged = "PET_BATTLE_PET_CHANGED",
    petBattlePetRoundPlaybackComplete = "PET_BATTLE_PET_ROUND_PLAYBACK_COMPLETE",
    petBattlePetRoundResults = "PET_BATTLE_PET_ROUND_RESULTS",
    petBattlePetTypeChanged = "PET_BATTLE_PET_TYPE_CHANGED",
    petBattlePvpDuelRequestCancel = "PET_BATTLE_PVP_DUEL_REQUEST_CANCEL",
    petBattlePvpDuelRequested = "PET_BATTLE_PVP_DUEL_REQUESTED",
    petBattleQueueProposalAccepted = "PET_BATTLE_QUEUE_PROPOSAL_ACCEPTED",
    petBattleQueueProposalDeclined = "PET_BATTLE_QUEUE_PROPOSAL_DECLINED",
    petBattleQueueProposeMatch = "PET_BATTLE_QUEUE_PROPOSE_MATCH",
    petBattleQueueStatus = "PET_BATTLE_QUEUE_STATUS",
    petBattleXpChanged = "PET_BATTLE_XP_CHANGED",
    petDismissStart = "PET_DISMISS_START",
    petForceNameDeclension = "PET_FORCE_NAME_DECLENSION",
    petInfoUpdate = "PET_INFO_UPDATE",
    petJournalAutoSlottedPet = "PET_JOURNAL_AUTO_SLOTTED_PET",
    petJournalCageFailed = "PET_JOURNAL_CAGE_FAILED",
    petJournalListUpdate = "PET_JOURNAL_LIST_UPDATE",
    petJournalNewBattleSlot = "PET_JOURNAL_NEW_BATTLE_SLOT",
    petJournalPetDeleted = "PET_JOURNAL_PET_DELETED",
    petJournalPetRestored = "PET_JOURNAL_PET_RESTORED",
    petJournalPetRevoked = "PET_JOURNAL_PET_REVOKED",
    petJournalPetsHealed = "PET_JOURNAL_PETS_HEALED",
    petJournalTrapLevelSet = "PET_JOURNAL_TRAP_LEVEL_SET",
    petSpecializationChanged = "PET_SPECIALIZATION_CHANGED",
    petSpellPowerUpdate = "PET_SPELL_POWER_UPDATE",
    petStableClosed = "PET_STABLE_CLOSED",
    petStableFavoritesUpdated = "PET_STABLE_FAVORITES_UPDATED",
    petStableShow = "PET_STABLE_SHOW",
    petStableUpdate = "PET_STABLE_UPDATE",
    petUiClose = "PET_UI_CLOSE",
    petUiUpdate = "PET_UI_UPDATE",
    petitionClosed = "PETITION_CLOSED",
    petitionShow = "PETITION_SHOW",
    photoSharingAuthorizationNeeded = "PHOTO_SHARING_AUTHORIZATION_NEEDED",
    photoSharingAuthorizationUpdated = "PHOTO_SHARING_AUTHORIZATION_UPDATED",
    photoSharingPhotoUploadStatus = "PHOTO_SHARING_PHOTO_UPLOAD_STATUS",
    photoSharingScreenshotReady = "PHOTO_SHARING_SCREENSHOT_READY",
    photoSharingThirdPartyAuthorizationNeeded = "PHOTO_SHARING_THIRD_PARTY_AUTHORIZATION_NEEDED",
    pingSystemError = "PING_SYSTEM_ERROR",
    playMovie = "PLAY_MOVIE",
    playerAccountBankTabSlotsChanged = "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED",
    playerAlive = "PLAYER_ALIVE",
    playerAvgItemLevelUpdate = "PLAYER_AVG_ITEM_LEVEL_UPDATE",
    playerCamping = "PLAYER_CAMPING",
    playerCanGlideChanged = "PLAYER_CAN_GLIDE_CHANGED",
    playerCharacterListUpdated = "PLAYER_CHARACTER_LIST_UPDATED",
    playerChoiceClose = "PLAYER_CHOICE_CLOSE",
    playerChoiceUpdate = "PLAYER_CHOICE_UPDATE",
    playerControlGained = "PLAYER_CONTROL_GAINED",
    playerControlLost = "PLAYER_CONTROL_LOST",
    playerDamageDoneMods = "PLAYER_DAMAGE_DONE_MODS",
    playerDead = "PLAYER_DEAD",
    playerDifficultyChanged = "PLAYER_DIFFICULTY_CHANGED",
    playerEnterCombat = "PLAYER_ENTER_COMBAT",
    playerEnteringBattleground = "PLAYER_ENTERING_BATTLEGROUND",
    playerEnteringWorld = "PLAYER_ENTERING_WORLD",
    playerEquipmentChanged = "PLAYER_EQUIPMENT_CHANGED",
    playerFarsightFocusChanged = "PLAYER_FARSIGHT_FOCUS_CHANGED",
    playerFlagsChanged = "PLAYER_FLAGS_CHANGED",
    playerFocusChanged = "PLAYER_FOCUS_CHANGED",
    playerGainsVehicleData = "PLAYER_GAINS_VEHICLE_DATA",
    playerGuildUpdate = "PLAYER_GUILD_UPDATE",
    playerHouseListUpdated = "PLAYER_HOUSE_LIST_UPDATED",
    playerImpulseApplied = "PLAYER_IMPULSE_APPLIED",
    playerInCombatChanged = "PLAYER_IN_COMBAT_CHANGED",
    playerInsideQuestBlobStateChanged = "PLAYER_INSIDE_QUEST_BLOB_STATE_CHANGED",
    playerInteractionManagerFrameHide = "PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
    playerInteractionManagerFrameShow = "PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
    playerIsGlidingChanged = "PLAYER_IS_GLIDING_CHANGED",
    playerJoinedPvpMatch = "PLAYER_JOINED_PVP_MATCH",
    playerLearnPvpTalentFailed = "PLAYER_LEARN_PVP_TALENT_FAILED",
    playerLearnTalentFailed = "PLAYER_LEARN_TALENT_FAILED",
    playerLeaveCombat = "PLAYER_LEAVE_COMBAT",
    playerLeavingWorld = "PLAYER_LEAVING_WORLD",
    playerLevelChanged = "PLAYER_LEVEL_CHANGED",
    playerLevelUp = "PLAYER_LEVEL_UP",
    playerLogin = "PLAYER_LOGIN",
    playerLogout = "PLAYER_LOGOUT",
    playerLootSpecUpdated = "PLAYER_LOOT_SPEC_UPDATED",
    playerLosesVehicleData = "PLAYER_LOSES_VEHICLE_DATA",
    playerMapChanged = "PLAYER_MAP_CHANGED",
    playerMaxLevelUpdate = "PLAYER_MAX_LEVEL_UPDATE",
    playerMoney = "PLAYER_MONEY",
    playerMountDisplayChanged = "PLAYER_MOUNT_DISPLAY_CHANGED",
    playerPvpKillsChanged = "PLAYER_PVP_KILLS_CHANGED",
    playerPvpRankChanged = "PLAYER_PVP_RANK_CHANGED",
    playerPvpTalentUpdate = "PLAYER_PVP_TALENT_UPDATE",
    playerQuiting = "PLAYER_QUITING",
    playerRegenDisabled = "PLAYER_REGEN_DISABLED",
    playerRegenEnabled = "PLAYER_REGEN_ENABLED",
    playerReportSubmitted = "PLAYER_REPORT_SUBMITTED",
    playerRolesAssigned = "PLAYER_ROLES_ASSIGNED",
    playerSkinned = "PLAYER_SKINNED",
    playerSoftEnemyChanged = "PLAYER_SOFT_ENEMY_CHANGED",
    playerSoftFriendChanged = "PLAYER_SOFT_FRIEND_CHANGED",
    playerSoftInteractChanged = "PLAYER_SOFT_INTERACT_CHANGED",
    playerSoftTargetInteraction = "PLAYER_SOFT_TARGET_INTERACTION",
    playerSpecializationChanged = "PLAYER_SPECIALIZATION_CHANGED",
    playerStartedLooking = "PLAYER_STARTED_LOOKING",
    playerStartedMoving = "PLAYER_STARTED_MOVING",
    playerStartedTurning = "PLAYER_STARTED_TURNING",
    playerStoppedLooking = "PLAYER_STOPPED_LOOKING",
    playerStoppedMoving = "PLAYER_STOPPED_MOVING",
    playerStoppedTurning = "PLAYER_STOPPED_TURNING",
    playerTalentUpdate = "PLAYER_TALENT_UPDATE",
    playerTargetChanged = "PLAYER_TARGET_CHANGED",
    playerTargetDied = "PLAYER_TARGET_DIED",
    playerTotemUpdate = "PLAYER_TOTEM_UPDATE",
    playerTradeCurrency = "PLAYER_TRADE_CURRENCY",
    playerTradeMoney = "PLAYER_TRADE_MONEY",
    playerTrialXpUpdate = "PLAYER_TRIAL_XP_UPDATE",
    playerUnghost = "PLAYER_UNGHOST",
    playerUpdateResting = "PLAYER_UPDATE_RESTING",
    playerXpUpdate = "PLAYER_XP_UPDATE",
    playerbankslotsChanged = "PLAYERBANKSLOTS_CHANGED",
    portraitsUpdated = "PORTRAITS_UPDATED",
    postMatchCurrencyRewardUpdate = "POST_MATCH_CURRENCY_REWARD_UPDATE",
    postMatchItemRewardUpdate = "POST_MATCH_ITEM_REWARD_UPDATE",
    professionEquipmentChanged = "PROFESSION_EQUIPMENT_CHANGED",
    professionRespecConfirmation = "PROFESSION_RESPEC_CONFIRMATION",
    provingGroundsScoreUpdate = "PROVING_GROUNDS_SCORE_UPDATE",
    purchasePlotResult = "PURCHASE_PLOT_RESULT",
    pvpBrawlInfoUpdated = "PVP_BRAWL_INFO_UPDATED",
    pvpMatchActive = "PVP_MATCH_ACTIVE",
    pvpMatchComplete = "PVP_MATCH_COMPLETE",
    pvpMatchInactive = "PVP_MATCH_INACTIVE",
    pvpMatchStateChanged = "PVP_MATCH_STATE_CHANGED",
    pvpPowerUpdate = "PVP_POWER_UPDATE",
    pvpRatedStatsUpdate = "PVP_RATED_STATS_UPDATE",
    pvpRewardsUpdate = "PVP_REWARDS_UPDATE",
    pvpRolePopupHide = "PVP_ROLE_POPUP_HIDE",
    pvpRolePopupShow = "PVP_ROLE_POPUP_SHOW",
    pvpRoleUpdate = "PVP_ROLE_UPDATE",
    pvpSpecialEventInfoUpdated = "PVP_SPECIAL_EVENT_INFO_UPDATED",
    pvpTimerUpdate = "PVP_TIMER_UPDATE",
    pvpTypesEnabled = "PVP_TYPES_ENABLED",
    pvpVehicleInfoUpdated = "PVP_VEHICLE_INFO_UPDATED",
    pvpWorldstateUpdate = "PVP_WORLDSTATE_UPDATE",
    pvpqueueAnywhereShow = "PVPQUEUE_ANYWHERE_SHOW",
    pvpqueueAnywhereUpdateAvailable = "PVPQUEUE_ANYWHERE_UPDATE_AVAILABLE",
    questAcceptConfirm = "QUEST_ACCEPT_CONFIRM",
    questAccepted = "QUEST_ACCEPTED",
    questAutocomplete = "QUEST_AUTOCOMPLETE",
    questBossEmote = "QUEST_BOSS_EMOTE",
    questComplete = "QUEST_COMPLETE",
    questCurrencyLootReceived = "QUEST_CURRENCY_LOOT_RECEIVED",
    questDataLoadResult = "QUEST_DATA_LOAD_RESULT",
    questDetail = "QUEST_DETAIL",
    questFinished = "QUEST_FINISHED",
    questGreeting = "QUEST_GREETING",
    questItemUpdate = "QUEST_ITEM_UPDATE",
    questLogCriteriaUpdate = "QUEST_LOG_CRITERIA_UPDATE",
    questLogUpdate = "QUEST_LOG_UPDATE",
    questLootReceived = "QUEST_LOOT_RECEIVED",
    questPoiUpdate = "QUEST_POI_UPDATE",
    questProgress = "QUEST_PROGRESS",
    questRemoved = "QUEST_REMOVED",
    questSessionCreated = "QUEST_SESSION_CREATED",
    questSessionDestroyed = "QUEST_SESSION_DESTROYED",
    questSessionEnabledStateChanged = "QUEST_SESSION_ENABLED_STATE_CHANGED",
    questSessionJoined = "QUEST_SESSION_JOINED",
    questSessionLeft = "QUEST_SESSION_LEFT",
    questSessionMemberConfirm = "QUEST_SESSION_MEMBER_CONFIRM",
    questSessionMemberStartResponse = "QUEST_SESSION_MEMBER_START_RESPONSE",
    questSessionNotification = "QUEST_SESSION_NOTIFICATION",
    questTurnedIn = "QUEST_TURNED_IN",
    questWatchListChanged = "QUEST_WATCH_LIST_CHANGED",
    questWatchUpdate = "QUEST_WATCH_UPDATE",
    questlineUpdate = "QUESTLINE_UPDATE",
    quickTicketSystemStatus = "QUICK_TICKET_SYSTEM_STATUS",
    quickTicketThrottleChanged = "QUICK_TICKET_THROTTLE_CHANGED",
    rafEntitlementDelivered = "RAF_ENTITLEMENT_DELIVERED",
    rafInfoUpdated = "RAF_INFO_UPDATED",
    rafRecruitingEnabledStatus = "RAF_RECRUITING_ENABLED_STATUS",
    rafRewardClaimFailed = "RAF_REWARD_CLAIM_FAILED",
    rafSystemEnabledStatus = "RAF_SYSTEM_ENABLED_STATUS",
    rafSystemInfoUpdated = "RAF_SYSTEM_INFO_UPDATED",
    raidBossEmote = "RAID_BOSS_EMOTE",
    raidBossWhisper = "RAID_BOSS_WHISPER",
    raidInstanceWelcome = "RAID_INSTANCE_WELCOME",
    raidRosterUpdate = "RAID_ROSTER_UPDATE",
    raidTargetUpdate = "RAID_TARGET_UPDATE",
    raisedAsGhoul = "RAISED_AS_GHOUL",
    readyCheck = "READY_CHECK",
    readyCheckConfirm = "READY_CHECK_CONFIRM",
    readyCheckFinished = "READY_CHECK_FINISHED",
    receivedAchievementList = "RECEIVED_ACHIEVEMENT_LIST",
    receivedAchievementMemberList = "RECEIVED_ACHIEVEMENT_MEMBER_LIST",
    receivedHouseLevelRewards = "RECEIVED_HOUSE_LEVEL_REWARDS",
    recentAlliesCacheUpdate = "RECENT_ALLIES_CACHE_UPDATE",
    recentAlliesDataReady = "RECENT_ALLIES_DATA_READY",
    recentAlliesSystemStatusUpdated = "RECENT_ALLIES_SYSTEM_STATUS_UPDATED",
    recentAllyDataUpdated = "RECENT_ALLY_DATA_UPDATED",
    rejectedMatchmakingPartyInvite = "REJECTED_MATCHMAKING_PARTY_INVITE",
    remixArtifactItemSpecsLoaded = "REMIX_ARTIFACT_ITEM_SPECS_LOADED",
    remixArtifactUpdate = "REMIX_ARTIFACT_UPDATE",
    remixEndOfEvent = "REMIX_END_OF_EVENT",
    removeNeighborhoodCharterSignature = "REMOVE_NEIGHBORHOOD_CHARTER_SIGNATURE",
    replaceEnchant = "REPLACE_ENCHANT",
    replaceTradeskillEnchant = "REPLACE_TRADESKILL_ENCHANT",
    replicateItemListUpdate = "REPLICATE_ITEM_LIST_UPDATE",
    reportPlayerResult = "REPORT_PLAYER_RESULT",
    reportScreenshotReady = "REPORT_SCREENSHOT_READY",
    requestCemeteryListResponse = "REQUEST_CEMETERY_LIST_RESPONSE",
    requestInviteConfirmation = "REQUEST_INVITE_CONFIRMATION",
    requestedGuildRenameResult = "REQUESTED_GUILD_RENAME_RESULT",
    requiredGuildRenameResult = "REQUIRED_GUILD_RENAME_RESULT",
    researchArtifactComplete = "RESEARCH_ARTIFACT_COMPLETE",
    researchArtifactDigSiteUpdated = "RESEARCH_ARTIFACT_DIG_SITE_UPDATED",
    researchArtifactUpdate = "RESEARCH_ARTIFACT_UPDATE",
    resurrectRequest = "RESURRECT_REQUEST",
    roleChangedInform = "ROLE_CHANGED_INFORM",
    rolePollBegin = "ROLE_POLL_BEGIN",
    runePowerUpdate = "RUNE_POWER_UPDATE",
    runeTypeUpdate = "RUNE_TYPE_UPDATE",
    runeforgeLegendaryCraftingClosed = "RUNEFORGE_LEGENDARY_CRAFTING_CLOSED",
    runeforgeLegendaryCraftingOpened = "RUNEFORGE_LEGENDARY_CRAFTING_OPENED",
    runeforgePowerInfoUpdated = "RUNEFORGE_POWER_INFO_UPDATED",
    savedVariablesTooLarge = "SAVED_VARIABLES_TOO_LARGE",
    scenarioBonusObjectiveComplete = "SCENARIO_BONUS_OBJECTIVE_COMPLETE",
    scenarioBonusVisibilityUpdate = "SCENARIO_BONUS_VISIBILITY_UPDATE",
    scenarioCompleted = "SCENARIO_COMPLETED",
    scenarioCriteriaShowStateUpdate = "SCENARIO_CRITERIA_SHOW_STATE_UPDATE",
    scenarioCriteriaUpdate = "SCENARIO_CRITERIA_UPDATE",
    scenarioPoiUpdate = "SCENARIO_POI_UPDATE",
    scenarioSpellUpdate = "SCENARIO_SPELL_UPDATE",
    scenarioUpdate = "SCENARIO_UPDATE",
    scrappingMachineItemAdded = "SCRAPPING_MACHINE_ITEM_ADDED",
    scrappingMachineItemRemoved = "SCRAPPING_MACHINE_ITEM_REMOVED",
    scrappingMachinePendingItemChanged = "SCRAPPING_MACHINE_PENDING_ITEM_CHANGED",
    scrappingMachineScrappingFinished = "SCRAPPING_MACHINE_SCRAPPING_FINISHED",
    screenshotFailed = "SCREENSHOT_FAILED",
    screenshotStarted = "SCREENSHOT_STARTED",
    screenshotSucceeded = "SCREENSHOT_SUCCEEDED",
    scriptedAnimationsUpdate = "SCRIPTED_ANIMATIONS_UPDATE",
    searchDbLoaded = "SEARCH_DB_LOADED",
    secureTransferCancel = "SECURE_TRANSFER_CANCEL",
    secureTransferConfirmHousingPurchase = "SECURE_TRANSFER_CONFIRM_HOUSING_PURCHASE",
    secureTransferConfirmSendMail = "SECURE_TRANSFER_CONFIRM_SEND_MAIL",
    secureTransferConfirmTradeAccept = "SECURE_TRANSFER_CONFIRM_TRADE_ACCEPT",
    secureTransferHousingCurrencyPurchaseConfirmation = "SECURE_TRANSFER_HOUSING_CURRENCY_PURCHASE_CONFIRMATION",
    selectedLoadoutChanged = "SELECTED_LOADOUT_CHANGED",
    selfResSpellChanged = "SELF_RES_SPELL_CHANGED",
    sendMailCodChanged = "SEND_MAIL_COD_CHANGED",
    sendMailMoneyChanged = "SEND_MAIL_MONEY_CHANGED",
    setSeenProducts = "SET_SEEN_PRODUCTS",
    settingsLoaded = "SETTINGS_LOADED",
    settingsPanelOpen = "SETTINGS_PANEL_OPEN",
    shipmentCrafterClosed = "SHIPMENT_CRAFTER_CLOSED",
    shipmentCrafterInfo = "SHIPMENT_CRAFTER_INFO",
    shipmentCrafterOpened = "SHIPMENT_CRAFTER_OPENED",
    shipmentCrafterReagentUpdate = "SHIPMENT_CRAFTER_REAGENT_UPDATE",
    shipmentUpdate = "SHIPMENT_UPDATE",
    showDelvesCompanionConfigurationUI = "SHOW_DELVES_COMPANION_CONFIGURATION_UI",
    showEndOfMatchUI = "SHOW_END_OF_MATCH_UI",
    showFactionSelectUi = "SHOW_FACTION_SELECT_UI",
    showHyperlinkTooltip = "SHOW_HYPERLINK_TOOLTIP",
    showJourneysUI = "SHOW_JOURNEYS_UI",
    showLfgExpandSearchPrompt = "SHOW_LFG_EXPAND_SEARCH_PROMPT",
    showLootToast = "SHOW_LOOT_TOAST",
    showLootToastLegendaryLooted = "SHOW_LOOT_TOAST_LEGENDARY_LOOTED",
    showLootToastUpgrade = "SHOW_LOOT_TOAST_UPGRADE",
    showNeighborhoodOwnershipTransferDialog = "SHOW_NEIGHBORHOOD_OWNERSHIP_TRANSFER_DIALOG",
    showNewProductNotification = "SHOW_NEW_PRODUCT_NOTIFICATION",
    showPartyPoseUI = "SHOW_PARTY_POSE_UI",
    showPlayerEvictedDialog = "SHOW_PLAYER_EVICTED_DIALOG",
    showPvpFactionLootToast = "SHOW_PVP_FACTION_LOOT_TOAST",
    showRatedPvpRewardToast = "SHOW_RATED_PVP_REWARD_TOAST",
    showStairDirectionConfirmation = "SHOW_STAIR_DIRECTION_CONFIRMATION",
    showSubscriptionInterstitial = "SHOW_SUBSCRIPTION_INTERSTITIAL",
    showSubtitle = "SHOW_SUBTITLE",
    simpleBrowserPopup = "SIMPLE_BROWSER_POPUP",
    simpleBrowserSocialCallbackInvoked = "SIMPLE_BROWSER_SOCIAL_CALLBACK_INVOKED",
    simpleBrowserWebError = "SIMPLE_BROWSER_WEB_ERROR",
    simpleBrowserWebProxyFailed = "SIMPLE_BROWSER_WEB_PROXY_FAILED",
    simpleCheckoutClosed = "SIMPLE_CHECKOUT_CLOSED",
    skillLineSpecsRanksChanged = "SKILL_LINE_SPECS_RANKS_CHANGED",
    skillLineSpecsUnlocked = "SKILL_LINE_SPECS_UNLOCKED",
    skillLinesChanged = "SKILL_LINES_CHANGED",
    socialQueueConfigUpdated = "SOCIAL_QUEUE_CONFIG_UPDATED",
    socialQueueUpdate = "SOCIAL_QUEUE_UPDATE",
    socialUIFriendsListSystemStatusUpdated = "SOCIAL_UI_FRIENDS_LIST_SYSTEM_STATUS_UPDATED",
    socialUISocialQueueSystemStatusUpdated = "SOCIAL_UI_SOCIAL_QUEUE_SYSTEM_STATUS_UPDATED",
    socialUISystemStatusUpdated = "SOCIAL_UI_SYSTEM_STATUS_UPDATED",
    socketInfoAccept = "SOCKET_INFO_ACCEPT",
    socketInfoBindConfirm = "SOCKET_INFO_BIND_CONFIRM",
    socketInfoClose = "SOCKET_INFO_CLOSE",
    socketInfoFailure = "SOCKET_INFO_FAILURE",
    socketInfoRefundableConfirm = "SOCKET_INFO_REFUNDABLE_CONFIRM",
    socketInfoSuccess = "SOCKET_INFO_SUCCESS",
    socketInfoUiEventRegistrationUpdate = "SOCKET_INFO_UI_EVENT_REGISTRATION_UPDATE",
    socketInfoUpdate = "SOCKET_INFO_UPDATE",
    soulbindActivated = "SOULBIND_ACTIVATED",
    soulbindConduitCollectionCleared = "SOULBIND_CONDUIT_COLLECTION_CLEARED",
    soulbindConduitCollectionRemoved = "SOULBIND_CONDUIT_COLLECTION_REMOVED",
    soulbindConduitCollectionUpdated = "SOULBIND_CONDUIT_COLLECTION_UPDATED",
    soulbindConduitInstalled = "SOULBIND_CONDUIT_INSTALLED",
    soulbindConduitUninstalled = "SOULBIND_CONDUIT_UNINSTALLED",
    soulbindForgeInteractionEnded = "SOULBIND_FORGE_INTERACTION_ENDED",
    soulbindForgeInteractionStarted = "SOULBIND_FORGE_INTERACTION_STARTED",
    soulbindNodeLearned = "SOULBIND_NODE_LEARNED",
    soulbindNodeUnlearned = "SOULBIND_NODE_UNLEARNED",
    soulbindNodeUpdated = "SOULBIND_NODE_UPDATED",
    soulbindPathChanged = "SOULBIND_PATH_CHANGED",
    soulbindPendingConduitChanged = "SOULBIND_PENDING_CONDUIT_CHANGED",
    soundDeviceUpdate = "SOUND_DEVICE_UPDATE",
    soundkitFinished = "SOUNDKIT_FINISHED",
    specInvoluntarilyChanged = "SPEC_INVOLUNTARILY_CHANGED",
    specializationChangeCastFailed = "SPECIALIZATION_CHANGE_CAST_FAILED",
    speedUpdate = "SPEED_UPDATE",
    spellActivationOverlayGlowHide = "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE",
    spellActivationOverlayGlowShow = "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW",
    spellActivationOverlayHide = "SPELL_ACTIVATION_OVERLAY_HIDE",
    spellActivationOverlayShow = "SPELL_ACTIVATION_OVERLAY_SHOW",
    spellConfirmationPrompt = "SPELL_CONFIRMATION_PROMPT",
    spellConfirmationTimeout = "SPELL_CONFIRMATION_TIMEOUT",
    spellDataLoadResult = "SPELL_DATA_LOAD_RESULT",
    spellFlyoutUpdate = "SPELL_FLYOUT_UPDATE",
    spellPowerChanged = "SPELL_POWER_CHANGED",
    spellPushedToActionbar = "SPELL_PUSHED_TO_ACTIONBAR",
    spellPushedToFlyoutOnActionbar = "SPELL_PUSHED_TO_FLYOUT_ON_ACTIONBAR",
    spellRangeCheckUpdate = "SPELL_RANGE_CHECK_UPDATE",
    spellTextUpdate = "SPELL_TEXT_UPDATE",
    spellUpdateCharges = "SPELL_UPDATE_CHARGES",
    spellUpdateCooldown = "SPELL_UPDATE_COOLDOWN",
    spellUpdateIcon = "SPELL_UPDATE_ICON",
    spellUpdateUsable = "SPELL_UPDATE_USABLE",
    spellUpdateUses = "SPELL_UPDATE_USES",
    spellsChanged = "SPELLS_CHANGED",
    startAutorepeatSpell = "START_AUTOREPEAT_SPELL",
    startLootRoll = "START_LOOT_ROLL",
    startPlayerCountdown = "START_PLAYER_COUNTDOWN",
    startTimer = "START_TIMER",
    starterBuildActivationFailed = "STARTER_BUILD_ACTIVATION_FAILED",
    stopAutorepeatSpell = "STOP_AUTOREPEAT_SPELL",
    stopMovie = "STOP_MOVIE",
    stopTimerOfType = "STOP_TIMER_OF_TYPE",
    storeFrontStateUpdated = "STORE_FRONT_STATE_UPDATED",
    streamViewMarkerUpdated = "STREAM_VIEW_MARKER_UPDATED",
    streamingIcon = "STREAMING_ICON",
    sturdinessUpdate = "STURDINESS_UPDATE",
    superTrackingChanged = "SUPER_TRACKING_CHANGED",
    superTrackingPathUpdated = "SUPER_TRACKING_PATH_UPDATED",
    surveyDelivered = "SURVEY_DELIVERED",
    sysmsg = "SYSMSG",
    systemVisibilityChanged = "SYSTEM_VISIBILITY_CHANGED",
    tabardCansaveChanged = "TABARD_CANSAVE_CHANGED",
    tabardSavePending = "TABARD_SAVE_PENDING",
    talentsInvoluntarilyReset = "TALENTS_INVOLUNTARILY_RESET",
    talkingheadClose = "TALKINGHEAD_CLOSE",
    talkingheadRequested = "TALKINGHEAD_REQUESTED",
    taskProgressUpdate = "TASK_PROGRESS_UPDATE",
    taxiNodeStatusChanged = "TAXI_NODE_STATUS_CHANGED",
    taximapClosed = "TAXIMAP_CLOSED",
    taximapOpened = "TAXIMAP_OPENED",
    timePlayedMsg = "TIME_PLAYED_MSG",
    toggleConsole = "TOGGLE_CONSOLE",
    tokenAuctionSold = "TOKEN_AUCTION_SOLD",
    tokenBuyConfirmRequired = "TOKEN_BUY_CONFIRM_REQUIRED",
    tokenBuyResult = "TOKEN_BUY_RESULT",
    tokenCanVeteranBuyUpdate = "TOKEN_CAN_VETERAN_BUY_UPDATE",
    tokenDistributionsUpdated = "TOKEN_DISTRIBUTIONS_UPDATED",
    tokenMarketPriceUpdated = "TOKEN_MARKET_PRICE_UPDATED",
    tokenRedeemBalanceUpdated = "TOKEN_REDEEM_BALANCE_UPDATED",
    tokenRedeemConfirmRequired = "TOKEN_REDEEM_CONFIRM_REQUIRED",
    tokenRedeemFrameShow = "TOKEN_REDEEM_FRAME_SHOW",
    tokenRedeemGameTimeUpdated = "TOKEN_REDEEM_GAME_TIME_UPDATED",
    tokenRedeemResult = "TOKEN_REDEEM_RESULT",
    tokenSellConfirmRequired = "TOKEN_SELL_CONFIRM_REQUIRED",
    tokenSellConfirmed = "TOKEN_SELL_CONFIRMED",
    tokenSellResult = "TOKEN_SELL_RESULT",
    tokenStatusChanged = "TOKEN_STATUS_CHANGED",
    tooltipDataUpdate = "TOOLTIP_DATA_UPDATE",
    tooltipShowItemComparison = "TOOLTIP_SHOW_ITEM_COMPARISON",
    toysUpdated = "TOYS_UPDATED",
    trackableInfoUpdate = "TRACKABLE_INFO_UPDATE",
    trackedAchievementListChanged = "TRACKED_ACHIEVEMENT_LIST_CHANGED",
    trackedAchievementUpdate = "TRACKED_ACHIEVEMENT_UPDATE",
    trackedHouseChanged = "TRACKED_HOUSE_CHANGED",
    trackedRecipeUpdate = "TRACKED_RECIPE_UPDATE",
    trackingTargetInfoUpdate = "TRACKING_TARGET_INFO_UPDATE",
    tradeAcceptUpdate = "TRADE_ACCEPT_UPDATE",
    tradeClosed = "TRADE_CLOSED",
    tradeCurrencyChanged = "TRADE_CURRENCY_CHANGED",
    tradeMoneyChanged = "TRADE_MONEY_CHANGED",
    tradePlayerItemChanged = "TRADE_PLAYER_ITEM_CHANGED",
    tradePotentialBindEnchant = "TRADE_POTENTIAL_BIND_ENCHANT",
    tradePotentialRemoveTransmog = "TRADE_POTENTIAL_REMOVE_TRANSMOG",
    tradeReplaceEnchant = "TRADE_REPLACE_ENCHANT",
    tradeRequest = "TRADE_REQUEST",
    tradeRequestCancel = "TRADE_REQUEST_CANCEL",
    tradeShow = "TRADE_SHOW",
    tradeSkillClose = "TRADE_SKILL_CLOSE",
    tradeSkillCraftBegin = "TRADE_SKILL_CRAFT_BEGIN",
    tradeSkillCraftingReagentBonusTextUpdated = "TRADE_SKILL_CRAFTING_REAGENT_BONUS_TEXT_UPDATED",
    tradeSkillCurrencyRewardResult = "TRADE_SKILL_CURRENCY_REWARD_RESULT",
    tradeSkillDataSourceChanged = "TRADE_SKILL_DATA_SOURCE_CHANGED",
    tradeSkillDataSourceChanging = "TRADE_SKILL_DATA_SOURCE_CHANGING",
    tradeSkillDetailsUpdate = "TRADE_SKILL_DETAILS_UPDATE",
    tradeSkillFavoritesChanged = "TRADE_SKILL_FAVORITES_CHANGED",
    tradeSkillItemCraftedResult = "TRADE_SKILL_ITEM_CRAFTED_RESULT",
    tradeSkillItemUpdate = "TRADE_SKILL_ITEM_UPDATE",
    tradeSkillListUpdate = "TRADE_SKILL_LIST_UPDATE",
    tradeSkillNameUpdate = "TRADE_SKILL_NAME_UPDATE",
    tradeSkillShow = "TRADE_SKILL_SHOW",
    tradeTargetItemChanged = "TRADE_TARGET_ITEM_CHANGED",
    tradeUpdate = "TRADE_UPDATE",
    tradeUpdateWarnings = "TRADE_UPDATE_WARNINGS",
    trainerClosed = "TRAINER_CLOSED",
    trainerDescriptionUpdate = "TRAINER_DESCRIPTION_UPDATE",
    trainerServiceInfoNameUpdate = "TRAINER_SERVICE_INFO_NAME_UPDATE",
    trainerShow = "TRAINER_SHOW",
    trainerUpdate = "TRAINER_UPDATE",
    trainingGroundsEnabledStatusUpdated = "TRAINING_GROUNDS_ENABLED_STATUS_UPDATED",
    traitCondInfoChanged = "TRAIT_COND_INFO_CHANGED",
    traitConfigCreated = "TRAIT_CONFIG_CREATED",
    traitConfigDeleted = "TRAIT_CONFIG_DELETED",
    traitConfigListUpdated = "TRAIT_CONFIG_LIST_UPDATED",
    traitConfigUpdated = "TRAIT_CONFIG_UPDATED",
    traitNodeChanged = "TRAIT_NODE_CHANGED",
    traitNodeChangedPartial = "TRAIT_NODE_CHANGED_PARTIAL",
    traitNodeEntryUpdated = "TRAIT_NODE_ENTRY_UPDATED",
    traitSubTreeChanged = "TRAIT_SUB_TREE_CHANGED",
    traitSystemInteractionStarted = "TRAIT_SYSTEM_INTERACTION_STARTED",
    traitSystemNpcClosed = "TRAIT_SYSTEM_NPC_CLOSED",
    traitTreeChanged = "TRAIT_TREE_CHANGED",
    traitTreeCurrencyInfoUpdated = "TRAIT_TREE_CURRENCY_INFO_UPDATED",
    transmogCollectionCameraUpdate = "TRANSMOG_COLLECTION_CAMERA_UPDATE",
    transmogCollectionItemFavoriteUpdate = "TRANSMOG_COLLECTION_ITEM_FAVORITE_UPDATE",
    transmogCollectionItemUpdate = "TRANSMOG_COLLECTION_ITEM_UPDATE",
    transmogCollectionSourceAdded = "TRANSMOG_COLLECTION_SOURCE_ADDED",
    transmogCollectionSourceRemoved = "TRANSMOG_COLLECTION_SOURCE_REMOVED",
    transmogCollectionUpdated = "TRANSMOG_COLLECTION_UPDATED",
    transmogCosmeticCollectionSourceAdded = "TRANSMOG_COSMETIC_COLLECTION_SOURCE_ADDED",
    transmogCustomSetsChanged = "TRANSMOG_CUSTOM_SETS_CHANGED",
    transmogDisplayedOutfitChanged = "TRANSMOG_DISPLAYED_OUTFIT_CHANGED",
    transmogOutfitsChanged = "TRANSMOG_OUTFITS_CHANGED",
    transmogSearchUpdated = "TRANSMOG_SEARCH_UPDATED",
    transmogSetsUpdateFavorite = "TRANSMOG_SETS_UPDATE_FAVORITE",
    transmogSourceCollectabilityUpdate = "TRANSMOG_SOURCE_COLLECTABILITY_UPDATE",
    transmogrifyClose = "TRANSMOGRIFY_CLOSE",
    transmogrifyItemUpdate = "TRANSMOGRIFY_ITEM_UPDATE",
    transmogrifyOpen = "TRANSMOGRIFY_OPEN",
    transmogrifySuccess = "TRANSMOGRIFY_SUCCESS",
    transmogrifyUpdate = "TRANSMOGRIFY_UPDATE",
    treasurePickerCacheFlush = "TREASURE_PICKER_CACHE_FLUSH",
    trialCapReachedMoney = "TRIAL_CAP_REACHED_MONEY",
    tryPurchaseToNodePartialSuccess = "TRY_PURCHASE_TO_NODE_PARTIAL_SUCCESS",
    tutorialCombatEvent = "TUTORIAL_COMBAT_EVENT",
    tutorialHighlightSpell = "TUTORIAL_HIGHLIGHT_SPELL",
    tutorialTrigger = "TUTORIAL_TRIGGER",
    tutorialUnhighlightSpell = "TUTORIAL_UNHIGHLIGHT_SPELL",
    uiErrorMessage = "UI_ERROR_MESSAGE",
    uiErrorPopup = "UI_ERROR_POPUP",
    uiInfoMessage = "UI_INFO_MESSAGE",
    uiModelSceneInfoUpdated = "UI_MODEL_SCENE_INFO_UPDATED",
    uiScaleChanged = "UI_SCALE_CHANGED",
    unitAbsorbAmountChanged = "UNIT_ABSORB_AMOUNT_CHANGED",
    unitAreaChanged = "UNIT_AREA_CHANGED",
    unitArenaCooldownsUpdate = "UNIT_ARENA_COOLDOWNS_UPDATE",
    unitAttack = "UNIT_ATTACK",
    unitAttackPower = "UNIT_ATTACK_POWER",
    unitAttackSpeed = "UNIT_ATTACK_SPEED",
    unitAura = "UNIT_AURA",
    unitAuraBlockListCleared = "UNIT_AURA_BLOCK_LIST_CLEARED",
    unitAuraBlocked = "UNIT_AURA_BLOCKED",
    unitCheatToggleEvent = "UNIT_CHEAT_TOGGLE_EVENT",
    unitClassificationChanged = "UNIT_CLASSIFICATION_CHANGED",
    unitCombat = "UNIT_COMBAT",
    unitConnection = "UNIT_CONNECTION",
    unitCtrOptions = "UNIT_CTR_OPTIONS",
    unitDamage = "UNIT_DAMAGE",
    unitDefense = "UNIT_DEFENSE",
    unitDied = "UNIT_DIED",
    unitDisplaypower = "UNIT_DISPLAYPOWER",
    unitDistanceCheckUpdate = "UNIT_DISTANCE_CHECK_UPDATE",
    unitEnteredVehicle = "UNIT_ENTERED_VEHICLE",
    unitEnteringVehicle = "UNIT_ENTERING_VEHICLE",
    unitExitedVehicle = "UNIT_EXITED_VEHICLE",
    unitExitingVehicle = "UNIT_EXITING_VEHICLE",
    unitFaction = "UNIT_FACTION",
    unitFlags = "UNIT_FLAGS",
    unitFormChanged = "UNIT_FORM_CHANGED",
    unitGuildLevel = "UNIT_GUILD_LEVEL",
    unitHealAbsorbAmountChanged = "UNIT_HEAL_ABSORB_AMOUNT_CHANGED",
    unitHealPrediction = "UNIT_HEAL_PREDICTION",
    unitHealth = "UNIT_HEALTH",
    unitInRangeUpdate = "UNIT_IN_RANGE_UPDATE",
    unitInventoryChanged = "UNIT_INVENTORY_CHANGED",
    unitLevel = "UNIT_LEVEL",
    unitLoot = "UNIT_LOOT",
    unitMana = "UNIT_MANA",
    unitMaxHealthModifiersChanged = "UNIT_MAX_HEALTH_MODIFIERS_CHANGED",
    unitMaxhealth = "UNIT_MAXHEALTH",
    unitMaxpower = "UNIT_MAXPOWER",
    unitModelChanged = "UNIT_MODEL_CHANGED",
    unitNameUpdate = "UNIT_NAME_UPDATE",
    unitOtherPartyChanged = "UNIT_OTHER_PARTY_CHANGED",
    unitPet = "UNIT_PET",
    unitPetExperience = "UNIT_PET_EXPERIENCE",
    unitPhase = "UNIT_PHASE",
    unitPingPinAdded = "UNIT_PING_PIN_ADDED",
    unitPingPinRemoved = "UNIT_PING_PIN_REMOVED",
    unitPortraitUpdate = "UNIT_PORTRAIT_UPDATE",
    unitPowerBarHide = "UNIT_POWER_BAR_HIDE",
    unitPowerBarShow = "UNIT_POWER_BAR_SHOW",
    unitPowerBarTimerUpdate = "UNIT_POWER_BAR_TIMER_UPDATE",
    unitPowerFrequent = "UNIT_POWER_FREQUENT",
    unitPowerPointCharge = "UNIT_POWER_POINT_CHARGE",
    unitPowerUpdate = "UNIT_POWER_UPDATE",
    unitQuestLogChanged = "UNIT_QUEST_LOG_CHANGED",
    unitRangedAttackPower = "UNIT_RANGED_ATTACK_POWER",
    unitRangeddamage = "UNIT_RANGEDDAMAGE",
    unitResistances = "UNIT_RESISTANCES",
    unitSpellDiminishCategoryStateUpdated = "UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED",
    unitSpellHaste = "UNIT_SPELL_HASTE",
    unitSpellcastChannelStart = "UNIT_SPELLCAST_CHANNEL_START",
    unitSpellcastChannelStop = "UNIT_SPELLCAST_CHANNEL_STOP",
    unitSpellcastChannelUpdate = "UNIT_SPELLCAST_CHANNEL_UPDATE",
    unitSpellcastDelayed = "UNIT_SPELLCAST_DELAYED",
    unitSpellcastEmpowerStart = "UNIT_SPELLCAST_EMPOWER_START",
    unitSpellcastEmpowerStop = "UNIT_SPELLCAST_EMPOWER_STOP",
    unitSpellcastEmpowerUpdate = "UNIT_SPELLCAST_EMPOWER_UPDATE",
    unitSpellcastFailed = "UNIT_SPELLCAST_FAILED",
    unitSpellcastFailedQuiet = "UNIT_SPELLCAST_FAILED_QUIET",
    unitSpellcastInterrupted = "UNIT_SPELLCAST_INTERRUPTED",
    unitSpellcastInterruptible = "UNIT_SPELLCAST_INTERRUPTIBLE",
    unitSpellcastNotInterruptible = "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
    unitSpellcastReticleClear = "UNIT_SPELLCAST_RETICLE_CLEAR",
    unitSpellcastReticleTarget = "UNIT_SPELLCAST_RETICLE_TARGET",
    unitSpellcastSent = "UNIT_SPELLCAST_SENT",
    unitSpellcastStart = "UNIT_SPELLCAST_START",
    unitSpellcastStop = "UNIT_SPELLCAST_STOP",
    unitSpellcastSucceeded = "UNIT_SPELLCAST_SUCCEEDED",
    unitStats = "UNIT_STATS",
    unitTarget = "UNIT_TARGET",
    unitTargetableChanged = "UNIT_TARGETABLE_CHANGED",
    unitThreatListUpdate = "UNIT_THREAT_LIST_UPDATE",
    unitThreatSituationUpdate = "UNIT_THREAT_SITUATION_UPDATE",
    updateActiveBattlefield = "UPDATE_ACTIVE_BATTLEFIELD",
    updateAllUiWidgets = "UPDATE_ALL_UI_WIDGETS",
    updateBattlefieldScore = "UPDATE_BATTLEFIELD_SCORE",
    updateBattlefieldStatus = "UPDATE_BATTLEFIELD_STATUS",
    updateBindings = "UPDATE_BINDINGS",
    updateBonusActionbar = "UPDATE_BONUS_ACTIONBAR",
    updateBulletinBoardMemberType = "UPDATE_BULLETIN_BOARD_MEMBER_TYPE",
    updateBulletinBoardRoster = "UPDATE_BULLETIN_BOARD_ROSTER",
    updateBulletinBoardRosterStatuses = "UPDATE_BULLETIN_BOARD_ROSTER_STATUSES",
    updateChatColor = "UPDATE_CHAT_COLOR",
    updateChatColorNameByClass = "UPDATE_CHAT_COLOR_NAME_BY_CLASS",
    updateChatWindows = "UPDATE_CHAT_WINDOWS",
    updateExhaustion = "UPDATE_EXHAUSTION",
    updateExtraActionbar = "UPDATE_EXTRA_ACTIONBAR",
    updateFaction = "UPDATE_FACTION",
    updateFloatingChatWindows = "UPDATE_FLOATING_CHAT_WINDOWS",
    updateInstanceInfo = "UPDATE_INSTANCE_INFO",
    updateInventoryAlerts = "UPDATE_INVENTORY_ALERTS",
    updateInventoryDurability = "UPDATE_INVENTORY_DURABILITY",
    updateLfgList = "UPDATE_LFG_LIST",
    updateMacros = "UPDATE_MACROS",
    updateMasterLootList = "UPDATE_MASTER_LOOT_LIST",
    updateMouseoverUnit = "UPDATE_MOUSEOVER_UNIT",
    updateMultiCastActionbar = "UPDATE_MULTI_CAST_ACTIONBAR",
    updateOverrideActionbar = "UPDATE_OVERRIDE_ACTIONBAR",
    updatePendingMail = "UPDATE_PENDING_MAIL",
    updatePossessBar = "UPDATE_POSSESS_BAR",
    updateShapeshiftCooldown = "UPDATE_SHAPESHIFT_COOLDOWN",
    updateShapeshiftForm = "UPDATE_SHAPESHIFT_FORM",
    updateShapeshiftForms = "UPDATE_SHAPESHIFT_FORMS",
    updateShapeshiftUsable = "UPDATE_SHAPESHIFT_USABLE",
    updateSpellTargetItemContext = "UPDATE_SPELL_TARGET_ITEM_CONTEXT",
    updateStealth = "UPDATE_STEALTH",
    updateSummonpetsAction = "UPDATE_SUMMONPETS_ACTION",
    updateTradeskillCastStopped = "UPDATE_TRADESKILL_CAST_STOPPED",
    updateUiWidget = "UPDATE_UI_WIDGET",
    updateVehicleActionbar = "UPDATE_VEHICLE_ACTIONBAR",
    updateWebTicket = "UPDATE_WEB_TICKET",
    urlTextureRequestResult = "URL_TEXTURE_REQUEST_RESULT",
    useBindConfirm = "USE_BIND_CONFIRM",
    useCombinedBagsChanged = "USE_COMBINED_BAGS_CHANGED",
    useGlyph = "USE_GLYPH",
    useNoRefundConfirm = "USE_NO_REFUND_CONFIRM",
    userWaypointUpdated = "USER_WAYPOINT_UPDATED",
    variablesLoaded = "VARIABLES_LOADED",
    vehicleAngleShow = "VEHICLE_ANGLE_SHOW",
    vehicleAngleUpdate = "VEHICLE_ANGLE_UPDATE",
    vehiclePassengersChanged = "VEHICLE_PASSENGERS_CHANGED",
    vehiclePowerShow = "VEHICLE_POWER_SHOW",
    vehicleUpdate = "VEHICLE_UPDATE",
    viewHousesListRecieved = "VIEW_HOUSES_LIST_RECIEVED",
    viewedTransmogOutfitChanged = "VIEWED_TRANSMOG_OUTFIT_CHANGED",
    viewedTransmogOutfitSecondarySlotsChanged = "VIEWED_TRANSMOG_OUTFIT_SECONDARY_SLOTS_CHANGED",
    viewedTransmogOutfitSituationsChanged = "VIEWED_TRANSMOG_OUTFIT_SITUATIONS_CHANGED",
    viewedTransmogOutfitSlotRefresh = "VIEWED_TRANSMOG_OUTFIT_SLOT_REFRESH",
    viewedTransmogOutfitSlotSaveSuccess = "VIEWED_TRANSMOG_OUTFIT_SLOT_SAVE_SUCCESS",
    viewedTransmogOutfitSlotWeaponOptionChanged = "VIEWED_TRANSMOG_OUTFIT_SLOT_WEAPON_OPTION_CHANGED",
    vignetteMinimapUpdated = "VIGNETTE_MINIMAP_UPDATED",
    vignettesUpdated = "VIGNETTES_UPDATED",
    voiceChatActiveInputDeviceUpdated = "VOICE_CHAT_ACTIVE_INPUT_DEVICE_UPDATED",
    voiceChatActiveOutputDeviceUpdated = "VOICE_CHAT_ACTIVE_OUTPUT_DEVICE_UPDATED",
    voiceChatAudioCaptureEnergy = "VOICE_CHAT_AUDIO_CAPTURE_ENERGY",
    voiceChatAudioCaptureStarted = "VOICE_CHAT_AUDIO_CAPTURE_STARTED",
    voiceChatAudioCaptureStopped = "VOICE_CHAT_AUDIO_CAPTURE_STOPPED",
    voiceChatChannelActivated = "VOICE_CHAT_CHANNEL_ACTIVATED",
    voiceChatChannelDeactivated = "VOICE_CHAT_CHANNEL_DEACTIVATED",
    voiceChatChannelDisplayNameChanged = "VOICE_CHAT_CHANNEL_DISPLAY_NAME_CHANGED",
    voiceChatChannelJoined = "VOICE_CHAT_CHANNEL_JOINED",
    voiceChatChannelMemberActiveStateChanged = "VOICE_CHAT_CHANNEL_MEMBER_ACTIVE_STATE_CHANGED",
    voiceChatChannelMemberAdded = "VOICE_CHAT_CHANNEL_MEMBER_ADDED",
    voiceChatChannelMemberEnergyChanged = "VOICE_CHAT_CHANNEL_MEMBER_ENERGY_CHANGED",
    voiceChatChannelMemberGuidUpdated = "VOICE_CHAT_CHANNEL_MEMBER_GUID_UPDATED",
    voiceChatChannelMemberMuteForAllChanged = "VOICE_CHAT_CHANNEL_MEMBER_MUTE_FOR_ALL_CHANGED",
    voiceChatChannelMemberMuteForMeChanged = "VOICE_CHAT_CHANNEL_MEMBER_MUTE_FOR_ME_CHANGED",
    voiceChatChannelMemberRemoved = "VOICE_CHAT_CHANNEL_MEMBER_REMOVED",
    voiceChatChannelMemberSilencedChanged = "VOICE_CHAT_CHANNEL_MEMBER_SILENCED_CHANGED",
    voiceChatChannelMemberSpeakingStateChanged = "VOICE_CHAT_CHANNEL_MEMBER_SPEAKING_STATE_CHANGED",
    voiceChatChannelMemberSttMessage = "VOICE_CHAT_CHANNEL_MEMBER_STT_MESSAGE",
    voiceChatChannelMemberVolumeChanged = "VOICE_CHAT_CHANNEL_MEMBER_VOLUME_CHANGED",
    voiceChatChannelMuteStateChanged = "VOICE_CHAT_CHANNEL_MUTE_STATE_CHANGED",
    voiceChatChannelPttChanged = "VOICE_CHAT_CHANNEL_PTT_CHANGED",
    voiceChatChannelRemoved = "VOICE_CHAT_CHANNEL_REMOVED",
    voiceChatChannelTranscribingChanged = "VOICE_CHAT_CHANNEL_TRANSCRIBING_CHANGED",
    voiceChatChannelTransmitChanged = "VOICE_CHAT_CHANNEL_TRANSMIT_CHANGED",
    voiceChatChannelVolumeChanged = "VOICE_CHAT_CHANNEL_VOLUME_CHANGED",
    voiceChatCommunicationModeChanged = "VOICE_CHAT_COMMUNICATION_MODE_CHANGED",
    voiceChatConnectionSuccess = "VOICE_CHAT_CONNECTION_SUCCESS",
    voiceChatDeafenedChanged = "VOICE_CHAT_DEAFENED_CHANGED",
    voiceChatError = "VOICE_CHAT_ERROR",
    voiceChatInputDevicesUpdated = "VOICE_CHAT_INPUT_DEVICES_UPDATED",
    voiceChatLogin = "VOICE_CHAT_LOGIN",
    voiceChatLogout = "VOICE_CHAT_LOGOUT",
    voiceChatMutedChanged = "VOICE_CHAT_MUTED_CHANGED",
    voiceChatOutputDevicesUpdated = "VOICE_CHAT_OUTPUT_DEVICES_UPDATED",
    voiceChatPendingChannelJoinState = "VOICE_CHAT_PENDING_CHANNEL_JOIN_STATE",
    voiceChatPttButtonPressedStateChanged = "VOICE_CHAT_PTT_BUTTON_PRESSED_STATE_CHANGED",
    voiceChatSilencedChanged = "VOICE_CHAT_SILENCED_CHANGED",
    voiceChatSpeakForMeActiveStatusUpdated = "VOICE_CHAT_SPEAK_FOR_ME_ACTIVE_STATUS_UPDATED",
    voiceChatSpeakForMeFeatureStatusUpdated = "VOICE_CHAT_SPEAK_FOR_ME_FEATURE_STATUS_UPDATED",
    voiceChatTtsPlaybackBookmark = "VOICE_CHAT_TTS_PLAYBACK_BOOKMARK",
    voiceChatTtsPlaybackFailed = "VOICE_CHAT_TTS_PLAYBACK_FAILED",
    voiceChatTtsPlaybackFinished = "VOICE_CHAT_TTS_PLAYBACK_FINISHED",
    voiceChatTtsPlaybackStarted = "VOICE_CHAT_TTS_PLAYBACK_STARTED",
    voiceChatTtsSpeakTextUpdate = "VOICE_CHAT_TTS_SPEAK_TEXT_UPDATE",
    voiceChatTtsVoicesUpdate = "VOICE_CHAT_TTS_VOICES_UPDATE",
    voiceChatVadSettingsUpdated = "VOICE_CHAT_VAD_SETTINGS_UPDATED",
    voteKickReasonNeeded = "VOTE_KICK_REASON_NEEDED",
    walkInDataUpdate = "WALK_IN_DATA_UPDATE",
    warModeStatusUpdate = "WAR_MODE_STATUS_UPDATE",
    warbandSceneFavoritesUpdated = "WARBAND_SCENE_FAVORITES_UPDATED",
    warfrontCompleted = "WARFRONT_COMPLETED",
    wargameInviteSent = "WARGAME_INVITE_SENT",
    wargameRequestResponse = "WARGAME_REQUEST_RESPONSE",
    wargameRequested = "WARGAME_REQUESTED",
    waypointUpdate = "WAYPOINT_UPDATE",
    weaponEnchantChanged = "WEAPON_ENCHANT_CHANGED",
    weaponSlotChanged = "WEAPON_SLOT_CHANGED",
    weeklyRewardsItemChanged = "WEEKLY_REWARDS_ITEM_CHANGED",
    weeklyRewardsUpdate = "WEEKLY_REWARDS_UPDATE",
    whoListUpdate = "WHO_LIST_UPDATE",
    worldCursorTooltipUpdate = "WORLD_CURSOR_TOOLTIP_UPDATE",
    worldLootObjectInfoUpdated = "WORLD_LOOT_OBJECT_INFO_UPDATED",
    worldMapOpen = "WORLD_MAP_OPEN",
    worldPvpQueue = "WORLD_PVP_QUEUE",
    worldQuestCompletedBySpell = "WORLD_QUEST_COMPLETED_BY_SPELL",
    worldStateTimerStart = "WORLD_STATE_TIMER_START",
    worldStateTimerStop = "WORLD_STATE_TIMER_STOP",
    wowMouseNotFound = "WOW_MOUSE_NOT_FOUND",
    zoneChanged = "ZONE_CHANGED",
    zoneChangedIndoors = "ZONE_CHANGED_INDOORS",
    zoneChangedNewArea = "ZONE_CHANGED_NEW_AREA",
  }
  do
    local source = host.Enum or {}
    local target = {}
    api.enums = target
    target.abbreviationDataError = source.AbbreviationDataError
    target.accountCurrencyTransferResult = source.AccountCurrencyTransferResult
    target.accountData = source.AccountData
    target.accountDataUpdateStatus = source.AccountDataUpdateStatus
    target.accountExportResult = source.AccountExportResult
    target.accountGetListRequestType = source.AccountGetListRequestType
    target.accountSequenceCacheType = source.AccountSequenceCacheType
    target.accountTransType = source.AccountTransType
    target.actionBarOrientation = source.ActionBarOrientation
    target.actionBarVisibleSetting = source.ActionBarVisibleSetting
    target.addOnEnableState = source.AddOnEnableState
    target.addOnPerformanceMessageType = source.AddOnPerformanceMessageType
    target.addOnProfilerMetric = source.AddOnProfilerMetric
    target.addOnRestrictionState = source.AddOnRestrictionState
    target.addOnRestrictionType = source.AddOnRestrictionType
    target.addOnSecurityStatus = source.AddOnSecurityStatus
    target.addSoulbindConduitReason = source.AddSoulbindConduitReason
    target.animaDiversionNodeState = source.AnimaDiversionNodeState
    target.arrowCalloutDirection = source.ArrowCalloutDirection
    target.arrowCalloutType = source.ArrowCalloutType
    target.assistActionType = source.AssistActionType
    target.auctionHouseCommoditySortOrder = source.AuctionHouseCommoditySortOrder
    target.auctionHouseError = source.AuctionHouseError
    target.auctionHouseExtraColumn = source.AuctionHouseExtraColumn
    target.auctionHouseFilter = source.AuctionHouseFilter
    target.auctionHouseFilterCategory = source.AuctionHouseFilterCategory
    target.auctionHouseItemSortOrder = source.AuctionHouseItemSortOrder
    target.auctionHouseNotification = source.AuctionHouseNotification
    target.auctionHouseSortOrder = source.AuctionHouseSortOrder
    target.auctionHouseTimeLeftBand = source.AuctionHouseTimeLeftBand
    target.auctionStatus = source.AuctionStatus
    target.auraFrameIconDirection = source.AuraFrameIconDirection
    target.auraFrameIconWrap = source.AuraFrameIconWrap
    target.auraFrameOrientation = source.AuraFrameOrientation
    target.auraFrameVisibleSetting = source.AuraFrameVisibleSetting
    target.autoCompleteEntryFlag = source.AutoCompleteEntryFlag
    target.autoCompletePriority = source.AutoCompletePriority
    target.avgItemLevelCategories = source.AvgItemLevelCategories
    target.azeriteEssenceSlot = source.AzeriteEssenceSlot
    target.azeritePowerLevel = source.AzeritePowerLevel
    target.bagFlag = source.BagFlag
    target.bagIndex = source.BagIndex
    target.bagSlotFlags = source.BagSlotFlags
    target.bagsDirection = source.BagsDirection
    target.bagsOrientation = source.BagsOrientation
    target.balanceType = source.BalanceType
    target.bankLockedReason = source.BankLockedReason
    target.bankType = source.BankType
    target.base64Variant = source.Base64Variant
    target.battleNetFriendLevel = source.BattleNetFriendLevel
    target.battleNetFriendTag = source.BattleNetFriendTag
    target.battlePetAction = source.BattlePetAction
    target.battlePetBreedQuality = source.BattlePetBreedQuality
    target.battlePetOwner = source.BattlePetOwner
    target.battlePetSources = source.BattlePetSources
    target.bindingContext = source.BindingContext
    target.bindingSet = source.BindingSet
    target.bnetAccountFlag = source.BnetAccountFlag
    target.bonusStatIndex = source.BonusStatIndex
    target.brawlType = source.BrawlType
    target.bulkPurchaseResult = source.BulkPurchaseResult
    target.bulkPurchaseStatus = source.BulkPurchaseStatus
    target.bulkRefundResult = source.BulkRefundResult
    target.calendarCommandType = source.CalendarCommandType
    target.calendarErrorType = source.CalendarErrorType
    target.calendarEventBits = source.CalendarEventBits
    target.calendarEventRepeatOptions = source.CalendarEventRepeatOptions
    target.calendarEventType = source.CalendarEventType
    target.calendarFilterFlags = source.CalendarFilterFlags
    target.calendarGetEventType = source.CalendarGetEventType
    target.calendarHolidayFilterType = source.CalendarHolidayFilterType
    target.calendarInviteBits = source.CalendarInviteBits
    target.calendarInviteSortType = source.CalendarInviteSortType
    target.calendarInviteType = source.CalendarInviteType
    target.calendarModeratorStatus = source.CalendarModeratorStatus
    target.calendarStatus = source.CalendarStatus
    target.calendarTexturesType = source.CalendarTexturesType
    target.calendarType = source.CalendarType
    target.calendarWebActionType = source.CalendarWebActionType
    target.callingStates = source.CallingStates
    target.cameraModeAspectRatio = source.CameraModeAspectRatio
    target.campaignState = source.CampaignState
    target.canRedeemTokenForBalanceResult = source.CanRedeemTokenForBalanceResult
    target.captureBarWidgetFillDirectionType = source.CaptureBarWidgetFillDirectionType
    target.causeofdeath = source.Causeofdeath
    target.causeofdeathFlags = source.CauseofdeathFlags
    target.challengeModeHistoryFlags = source.ChallengeModeHistoryFlags
    target.challengeModeHistoryResult = source.ChallengeModeHistoryResult
    target.challengeModeHistoryStatus = source.ChallengeModeHistoryStatus
    target.channelPlayerFlags = source.ChannelPlayerFlags
    target.charCreateAnimTurnType = source.CharCreateAnimTurnType
    target.charCustomizationType = source.CharCustomizationType
    target.charSectionCondition = source.CharSectionCondition
    target.characterServiceInfoFlag = source.CharacterServiceInfoFlag
    target.chatChannelRuleset = source.ChatChannelRuleset
    target.chatChannelType = source.ChatChannelType
    target.chatToxityFilterOptOut = source.ChatToxityFilterOptOut
    target.chatWhisperTargetStatus = source.ChatWhisperTargetStatus
    target.chrCustomizationCategoryFlag = source.ChrCustomizationCategoryFlag
    target.chrCustomizationOptionType = source.ChrCustomizationOptionType
    target.chrModelFeatureFlags = source.ChrModelFeatureFlags
    target.cinematicType = source.CinematicType
    target.clickBindingInteraction = source.ClickBindingInteraction
    target.clickBindingType = source.ClickBindingType
    target.clientPlatformType = source.ClientPlatformType
    target.clientSceneType = source.ClientSceneType
    target.clientSettingsConfigFlag = source.ClientSettingsConfigFlag
    target.clubActionType = source.ClubActionType
    target.clubErrorType = source.ClubErrorType
    target.clubFieldType = source.ClubFieldType
    target.clubFinderApplicationUpdateType = source.ClubFinderApplicationUpdateType
    target.clubFinderClubPostingStatusFlags = source.ClubFinderClubPostingStatusFlags
    target.clubFinderDisableReason = source.ClubFinderDisableReason
    target.clubFinderPostingReportType = source.ClubFinderPostingReportType
    target.clubFinderRequestType = source.ClubFinderRequestType
    target.clubFinderSettingFlags = source.ClubFinderSettingFlags
    target.clubInvitationCandidateStatus = source.ClubInvitationCandidateStatus
    target.clubMemberPresence = source.ClubMemberPresence
    target.clubRemovedReason = source.ClubRemovedReason
    target.clubRestrictionReason = source.ClubRestrictionReason
    target.clubRoleIdentifier = source.ClubRoleIdentifier
    target.clubStreamNotificationFilter = source.ClubStreamNotificationFilter
    target.clubStreamType = source.ClubStreamType
    target.clubType = source.ClubType
    target.colorOverride = source.ColorOverride
    target.combatAudioAlertCastState = source.CombatAudioAlertCastState
    target.combatAudioAlertCategory = source.CombatAudioAlertCategory
    target.combatAudioAlertDebuffSelfAlertValues = source.CombatAudioAlertDebuffSelfAlertValues
    target.combatAudioAlertPartyPercentValues = source.CombatAudioAlertPartyPercentValues
    target.combatAudioAlertPercentValues = source.CombatAudioAlertPercentValues
    target.combatAudioAlertPlayerCastFormatValues = source.CombatAudioAlertPlayerCastFormatValues
    target.combatAudioAlertPlayerDebuffFormatValues =
      source.CombatAudioAlertPlayerDebuffFormatValues
    target.combatAudioAlertPlayerHealthFormatValues =
      source.CombatAudioAlertPlayerHealthFormatValues
    target.combatAudioAlertPlayerResourceFormatValues =
      source.CombatAudioAlertPlayerResourceFormatValues
    target.combatAudioAlertSayIfTargetedType = source.CombatAudioAlertSayIfTargetedType
    target.combatAudioAlertSpecSetting = source.CombatAudioAlertSpecSetting
    target.combatAudioAlertTargetCastFormatValues = source.CombatAudioAlertTargetCastFormatValues
    target.combatAudioAlertTargetDeathBehavior = source.CombatAudioAlertTargetDeathBehavior
    target.combatAudioAlertTargetHealthFormatValues =
      source.CombatAudioAlertTargetHealthFormatValues
    target.combatAudioAlertThrottle = source.CombatAudioAlertThrottle
    target.combatAudioAlertType = source.CombatAudioAlertType
    target.combatAudioAlertUnit = source.CombatAudioAlertUnit
    target.combatLogMessageOrder = source.CombatLogMessageOrder
    target.combatLogObject = source.CombatLogObject
    target.combatLogObjectTarget = source.CombatLogObjectTarget
    target.combinedQuestLogStatus = source.CombinedQuestLogStatus
    target.combinedQuestStatus = source.CombinedQuestStatus
    target.communicationMode = source.CommunicationMode
    target.companionConfigSlotTypes = source.CompanionConfigSlotTypes
    target.companionRoleType = source.CompanionRoleType
    target.compressionLevel = source.CompressionLevel
    target.compressionMethod = source.CompressionMethod
    target.configurationWarning = source.ConfigurationWarning
    target.confirmationPromptUIType = source.ConfirmationPromptUIType
    target.conquestProgressBarDisplayType = source.ConquestProgressBarDisplayType
    target.consoleCategory = source.ConsoleCategory
    target.consoleColorType = source.ConsoleColorType
    target.consoleCommandType = source.ConsoleCommandType
    target.contentTrackingError = source.ContentTrackingError
    target.contentTrackingResult = source.ContentTrackingResult
    target.contentTrackingStopType = source.ContentTrackingStopType
    target.contentTrackingTargetType = source.ContentTrackingTargetType
    target.contentTrackingType = source.ContentTrackingType
    target.contributionAppearanceFlags = source.ContributionAppearanceFlags
    target.contributionResult = source.ContributionResult
    target.contributionState = source.ContributionState
    target.cooldownSetLinkedSpellFlags = source.CooldownSetLinkedSpellFlags
    target.cooldownSetSpellFlags = source.CooldownSetSpellFlags
    target.cooldownViewerAddAlertStatus = source.CooldownViewerAddAlertStatus
    target.cooldownViewerAlertEventType = source.CooldownViewerAlertEventType
    target.cooldownViewerAlertType = source.CooldownViewerAlertType
    target.cooldownViewerBarContent = source.CooldownViewerBarContent
    target.cooldownViewerCategory = source.CooldownViewerCategory
    target.cooldownViewerIconDirection = source.CooldownViewerIconDirection
    target.cooldownViewerOrientation = source.CooldownViewerOrientation
    target.cooldownViewerSound = source.CooldownViewerSound
    target.cooldownViewerVisibleSetting = source.CooldownViewerVisibleSetting
    target.cornerstonePurchaseMode = source.CornerstonePurchaseMode
    target.covenantAbilityType = source.CovenantAbilityType
    target.covenantSkill = source.CovenantSkill
    target.covenantType = source.CovenantType
    target.craftingOrderCustomerCategoryType = source.CraftingOrderCustomerCategoryType
    target.craftingOrderDuration = source.CraftingOrderDuration
    target.craftingOrderFlags = source.CraftingOrderFlags
    target.craftingOrderItemFlags = source.CraftingOrderItemFlags
    target.craftingOrderItemType = source.CraftingOrderItemType
    target.craftingOrderReagentSource = source.CraftingOrderReagentSource
    target.craftingOrderReagentsType = source.CraftingOrderReagentsType
    target.craftingOrderResult = source.CraftingOrderResult
    target.craftingOrderSortType = source.CraftingOrderSortType
    target.craftingOrderState = source.CraftingOrderState
    target.craftingOrderType = source.CraftingOrderType
    target.craftingReagentItemFlag = source.CraftingReagentItemFlag
    target.craftingReagentType = source.CraftingReagentType
    target.createNeighborhoodErrorType = source.CreateNeighborhoodErrorType
    target.curioRarity = source.CurioRarity
    target.curioType = source.CurioType
    target.currencyConversionResult = source.CurrencyConversionResult
    target.currencyDestroyReason = source.CurrencyDestroyReason
    target.currencyFilterType = source.CurrencyFilterType
    target.currencyFlags = source.CurrencyFlags
    target.currencyFlagsB = source.CurrencyFlagsB
    target.currencyGainFlags = source.CurrencyGainFlags
    target.currencyTokenCategoryFlags = source.CurrencyTokenCategoryFlags
    target.currencyType = source.CurrencyType
    target.cursorStyle = source.CursorStyle
    target.cursormode = source.Cursormode
    target.customAuraButtonDispelTypeStealableFilter =
      source.CustomAuraButtonDispelTypeStealableFilter
    target.customAuraButtonDispelTypeTextureStyle = source.CustomAuraButtonDispelTypeTextureStyle
    target.customAuraButtonUpdateMode = source.CustomAuraButtonUpdateMode
    target.customBindingType = source.CustomBindingType
    target.damageMeterCombineSessionType = source.DamageMeterCombineSessionType
    target.damageMeterNumbers = source.DamageMeterNumbers
    target.damageMeterOverrideType = source.DamageMeterOverrideType
    target.damageMeterSessionType = source.DamageMeterSessionType
    target.damageMeterSourceDisplayType = source.DamageMeterSourceDisplayType
    target.damageMeterSpellDetailsDisplayType = source.DamageMeterSpellDetailsDisplayType
    target.damageMeterStorageType = source.DamageMeterStorageType
    target.damageMeterStyle = source.DamageMeterStyle
    target.damageMeterType = source.DamageMeterType
    target.damageMeterVisibility = source.DamageMeterVisibility
    target.damageclass = source.Damageclass
    target.damageclassType = source.DamageclassType
    target.disableAccountProfilesFlags = source.DisableAccountProfilesFlags
    target.discordAccountType = source.DiscordAccountType
    target.discordDisplayNameType = source.DiscordDisplayNameType
    target.discordGuildSettings = source.DiscordGuildSettings
    target.durationTextBindingProperty = source.DurationTextBindingProperty
    target.durationTimeModifier = source.DurationTimeModifier
    target.editModeAccountSetting = source.EditModeAccountSetting
    target.editModeActionBarSetting = source.EditModeActionBarSetting
    target.editModeActionBarSystemIndices = source.EditModeActionBarSystemIndices
    target.editModeArchaeologyBarSetting = source.EditModeArchaeologyBarSetting
    target.editModeAuraFrameSetting = source.EditModeAuraFrameSetting
    target.editModeAuraFrameSystemIndices = source.EditModeAuraFrameSystemIndices
    target.editModeBagsSetting = source.EditModeBagsSetting
    target.editModeCastBarSetting = source.EditModeCastBarSetting
    target.editModeChatFrameSetting = source.EditModeChatFrameSetting
    target.editModeCooldownViewerSetting = source.EditModeCooldownViewerSetting
    target.editModeCooldownViewerSystemIndices = source.EditModeCooldownViewerSystemIndices
    target.editModeDamageMeterSetting = source.EditModeDamageMeterSetting
    target.editModeDurabilityFrameSetting = source.EditModeDurabilityFrameSetting
    target.editModeEncounterEventsSetting = source.EditModeEncounterEventsSetting
    target.editModeEncounterEventsSystemIndices = source.EditModeEncounterEventsSystemIndices
    target.editModeLayoutType = source.EditModeLayoutType
    target.editModeLossOfControlSetting = source.EditModeLossOfControlSetting
    target.editModeMicroMenuSetting = source.EditModeMicroMenuSetting
    target.editModeMinimapSetting = source.EditModeMinimapSetting
    target.editModeObjectiveTrackerSetting = source.EditModeObjectiveTrackerSetting
    target.editModePersonalResourceDisplaySetting = source.EditModePersonalResourceDisplaySetting
    target.editModePresetLayouts = source.EditModePresetLayouts
    target.editModeRaidWarningSetting = source.EditModeRaidWarningSetting
    target.editModeSettingDisplayType = source.EditModeSettingDisplayType
    target.editModeStatusTrackingBarSetting = source.EditModeStatusTrackingBarSetting
    target.editModeStatusTrackingBarSystemIndices = source.EditModeStatusTrackingBarSystemIndices
    target.editModeSystem = source.EditModeSystem
    target.editModeTimerBarsSetting = source.EditModeTimerBarsSetting
    target.editModeUnitFrameSetting = source.EditModeUnitFrameSetting
    target.editModeUnitFrameSystemIndices = source.EditModeUnitFrameSystemIndices
    target.editModeVehicleSeatIndicatorSetting = source.EditModeVehicleSeatIndicatorSetting
    target.encounterEventCastState = source.EncounterEventCastState
    target.encounterEventColorTrigger = source.EncounterEventColorTrigger
    target.encounterEventIconmask = source.EncounterEventIconmask
    target.encounterEventSeverity = source.EncounterEventSeverity
    target.encounterEventSoundTrigger = source.EncounterEventSoundTrigger
    target.encounterEventsIconDirection = source.EncounterEventsIconDirection
    target.encounterEventsOrientation = source.EncounterEventsOrientation
    target.encounterEventsTooltipAnchor = source.EncounterEventsTooltipAnchor
    target.encounterEventsViewType = source.EncounterEventsViewType
    target.encounterEventsVisibility = source.EncounterEventsVisibility
    target.encounterLootDropRollState = source.EncounterLootDropRollState
    target.encounterTimelineEventSortDirection = source.EncounterTimelineEventSortDirection
    target.encounterTimelineEventSource = source.EncounterTimelineEventSource
    target.encounterTimelineEventState = source.EncounterTimelineEventState
    target.encounterTimelineIconSet = source.EncounterTimelineIconSet
    target.encounterTimelineTrack = source.EncounterTimelineTrack
    target.encounterTimelineTrackType = source.EncounterTimelineTrackType
    target.encounterTimelineViewType = source.EncounterTimelineViewType
    target.endOfMatchType = source.EndOfMatchType
    target.environmentalDamageFlags = source.EnvironmentalDamageFlags
    target.environmentaldamagetype = source.Environmentaldamagetype
    target.eventRealmQueues = source.EventRealmQueues
    target.eventToastDisplayType = source.EventToastDisplayType
    target.eventToastEventType = source.EventToastEventType
    target.eventToastFlags = source.EventToastFlags
    target.excludedCensorSources = source.ExcludedCensorSources
    target.expansionLandingPageType = source.ExpansionLandingPageType
    target.expansionLevel = source.ExpansionLevel
    target.flightPathFaction = source.FlightPathFaction
    target.flightPathState = source.FlightPathState
    target.followerAbilityCastResult = source.FollowerAbilityCastResult
    target.fontStringScaleAnimationMode = source.FontStringScaleAnimationMode
    target.forbiddenAspect = source.ForbiddenAspect
    target.fragmentID = source.FragmentID
    target.frameTutorialAccount = source.FrameTutorialAccount
    target.gamePadPowerLevel = source.GamePadPowerLevel
    target.gameRuleFlags = source.GameRuleFlags
    target.gameRuleType = source.GameRuleType
    target.garrAutoBoardIndex = source.GarrAutoBoardIndex
    target.garrAutoCombatSpellTutorialFlag = source.GarrAutoCombatSpellTutorialFlag
    target.garrAutoCombatTutorial = source.GarrAutoCombatTutorial
    target.garrAutoCombatantRole = source.GarrAutoCombatantRole
    target.garrAutoEventFlags = source.GarrAutoEventFlags
    target.garrAutoMissionEventType = source.GarrAutoMissionEventType
    target.garrAutoPreviewTargetType = source.GarrAutoPreviewTargetType
    target.garrFollowerMissionCompleteState = source.GarrFollowerMissionCompleteState
    target.garrFollowerQuality = source.GarrFollowerQuality
    target.garrTalentCostType = source.GarrTalentCostType
    target.garrTalentFeatureSubtype = source.GarrTalentFeatureSubtype
    target.garrTalentFeatureType = source.GarrTalentFeatureType
    target.garrTalentResearchCostSource = source.GarrTalentResearchCostSource
    target.garrTalentSocketType = source.GarrTalentSocketType
    target.garrTalentTreeType = source.GarrTalentTreeType
    target.garrTalentType = source.GarrTalentType
    target.garrTalentUI = source.GarrTalentUI
    target.garrisonFollowerType = source.GarrisonFollowerType
    target.garrisonTalentAvailability = source.GarrisonTalentAvailability
    target.garrisonType = source.GarrisonType
    target.gossipNpcOption = source.GossipNpcOption
    target.gossipNpcOptionDisplayFlags = source.GossipNpcOptionDisplayFlags
    target.gossipOptionRecFlags = source.GossipOptionRecFlags
    target.gossipOptionRewardType = source.GossipOptionRewardType
    target.gossipOptionStatus = source.GossipOptionStatus
    target.gossipOptionUIWidgetSetTypes = source.GossipOptionUIWidgetSetTypes
    target.graphicsValidationResult = source.GraphicsValidationResult
    target.groupBuffItemFlags = source.GroupBuffItemFlags
    target.guildErrorType = source.GuildErrorType
    target.holidayCalendarFlags = source.HolidayCalendarFlags
    target.holidayFlags = source.HolidayFlags
    target.houseEditingContext = source.HouseEditingContext
    target.houseEditorMode = source.HouseEditorMode
    target.houseEditorPlayerType = source.HouseEditorPlayerType
    target.houseExteriorWMODataFlags = source.HouseExteriorWMODataFlags
    target.houseFinderSuggestionReason = source.HouseFinderSuggestionReason
    target.houseLevelRewardType = source.HouseLevelRewardType
    target.houseLevelRewardValueType = source.HouseLevelRewardValueType
    target.houseOwnerError = source.HouseOwnerError
    target.houseVisitType = source.HouseVisitType
    target.housingBasicModeTargetType = source.HousingBasicModeTargetType
    target.housingBlueprintContentType = source.HousingBlueprintContentType
    target.housingBlueprintFlag = source.HousingBlueprintFlag
    target.housingBlueprintType = source.HousingBlueprintType
    target.housingBlueprintUnmetRequirementFlags = source.HousingBlueprintUnmetRequirementFlags
    target.housingBudgetType = source.HousingBudgetType
    target.housingCatalogEntryModelScenePresets = source.HousingCatalogEntryModelScenePresets
    target.housingCatalogEntrySize = source.HousingCatalogEntrySize
    target.housingCatalogEntryType = source.HousingCatalogEntryType
    target.housingCatalogSortType = source.HousingCatalogSortType
    target.housingCleanupModeTargetType = source.HousingCleanupModeTargetType
    target.housingCustomizeModeTargetType = source.HousingCustomizeModeTargetType
    target.housingDecorPlacementRestriction = source.HousingDecorPlacementRestriction
    target.housingDecorTheme = source.HousingDecorTheme
    target.housingExpertModeTargetType = source.HousingExpertModeTargetType
    target.housingExpertSubmodeRestriction = source.HousingExpertSubmodeRestriction
    target.housingFixtureDecorAction = source.HousingFixtureDecorAction
    target.housingFixtureFlags = source.HousingFixtureFlags
    target.housingFixtureSize = source.HousingFixtureSize
    target.housingFixtureType = source.HousingFixtureType
    target.housingHouseScope = source.HousingHouseScope
    target.housingIncrementType = source.HousingIncrementType
    target.housingItemToastType = source.HousingItemToastType
    target.housingLayoutCameraDirection = source.HousingLayoutCameraDirection
    target.housingLayoutPinType = source.HousingLayoutPinType
    target.housingLayoutRestriction = source.HousingLayoutRestriction
    target.housingLayoutStairDirection = source.HousingLayoutStairDirection
    target.housingPetBehaviorType = source.HousingPetBehaviorType
    target.housingPlotOwnerType = source.HousingPlotOwnerType
    target.housingPrecisionSubmode = source.HousingPrecisionSubmode
    target.housingResult = source.HousingResult
    target.housingRoomComponentCeilingType = source.HousingRoomComponentCeilingType
    target.housingRoomComponentDoorType = source.HousingRoomComponentDoorType
    target.housingRoomComponentFlags = source.HousingRoomComponentFlags
    target.housingRoomComponentFloorType = source.HousingRoomComponentFloorType
    target.housingRoomComponentOptionFlags = source.HousingRoomComponentOptionFlags
    target.housingRoomComponentOptionType = source.HousingRoomComponentOptionType
    target.housingRoomComponentStairType = source.HousingRoomComponentStairType
    target.housingRoomComponentTextureFlags = source.HousingRoomComponentTextureFlags
    target.housingRoomComponentType = source.HousingRoomComponentType
    target.housingRoomFlags = source.HousingRoomFlags
    target.housingThemeFlags = source.HousingThemeFlags
    target.housingThrottleType = source.HousingThrottleType
    target.iconAndTextShiftTextType = source.IconAndTextShiftTextType
    target.iconAndTextWidgetState = source.IconAndTextWidgetState
    target.iconState = source.IconState
    target.imageSharingResult = source.ImageSharingResult
    target.initiativeMilestoneFlags = source.InitiativeMilestoneFlags
    target.initiativeRewardFlags = source.InitiativeRewardFlags
    target.inputContext = source.InputContext
    target.inventoryType = source.InventoryType
    target.itemArmorSubclass = source.ItemArmorSubclass
    target.itemBind = source.ItemBind
    target.itemClass = source.ItemClass
    target.itemCollectionType = source.ItemCollectionType
    target.itemCommodityStatus = source.ItemCommodityStatus
    target.itemConsumableSubclass = source.ItemConsumableSubclass
    target.itemConversionFlags = source.ItemConversionFlags
    target.itemDisplayTextDisplayStyle = source.ItemDisplayTextDisplayStyle
    target.itemDisplayTooltipEnabledType = source.ItemDisplayTooltipEnabledType
    target.itemGemColor = source.ItemGemColor
    target.itemGemSubclass = source.ItemGemSubclass
    target.itemHousingSubclass = source.ItemHousingSubclass
    target.itemMiscellaneousSubclass = source.ItemMiscellaneousSubclass
    target.itemProfessionSubclass = source.ItemProfessionSubclass
    target.itemQuality = source.ItemQuality
    target.itemReagentSubclass = source.ItemReagentSubclass
    target.itemRecipeSubclass = source.ItemRecipeSubclass
    target.itemRecraftFlags = source.ItemRecraftFlags
    target.itemRedundancySlot = source.ItemRedundancySlot
    target.itemSlotFilterType = source.ItemSlotFilterType
    target.itemSocketInfoUIType = source.ItemSocketInfoUIType
    target.itemSocketType = source.ItemSocketType
    target.itemSubclassDisplay = source.ItemSubclassDisplay
    target.itemSubclassFlag = source.ItemSubclassFlag
    target.itemTryOnReason = source.ItemTryOnReason
    target.itemWeaponSubclass = source.ItemWeaponSubclass
    target.itemclassfilterflags = source.Itemclassfilterflags
    target.itemsetflags = source.Itemsetflags
    target.jailersTowerType = source.JailersTowerType
    target.journalEncounterFlags = source.JournalEncounterFlags
    target.journalEncounterIconFlags = source.JournalEncounterIconFlags
    target.journalEncounterItemFlags = source.JournalEncounterItemFlags
    target.journalEncounterLocFlags = source.JournalEncounterLocFlags
    target.journalEncounterSecTypes = source.JournalEncounterSecTypes
    target.journalEncounterSectionFlags = source.JournalEncounterSectionFlags
    target.journalInstanceFlags = source.JournalInstanceFlags
    target.journalLinkTypes = source.JournalLinkTypes
    target.languageFlag = source.LanguageFlag
    target.leavePartyConfirmReason = source.LeavePartyConfirmReason
    target.lfgEntryGeneralPlaystyle = source.LFGEntryGeneralPlaystyle
    target.lfgEntryPlaystyle = source.LFGEntryPlaystyle
    target.lfgListDisplayType = source.LFGListDisplayType
    target.lfgListFilter = source.LFGListFilter
    target.lfgRole = source.LFGRole
    target.lfgSlotInvalidReason = source.LFGSlotInvalidReason
    target.lightRadiusIndicatorType = source.LightRadiusIndicatorType
    target.limitedInputType = source.LimitedInputType
    target.linkedCurrencyFlags = source.LinkedCurrencyFlags
    target.loadConfigResult = source.LoadConfigResult
    target.logPriority = source.LogPriority
    target.logicLogicop = source.LogicLogicop
    target.logicMathop = source.LogicMathop
    target.logicRelop = source.LogicRelop
    target.loginTicketLicenses = source.LoginTicketLicenses
    target.lootMethod = source.LootMethod
    target.lootMethodStyles = source.LootMethodStyles
    target.lootSlotType = source.LootSlotType
    target.luaCurveType = source.LuaCurveType
    target.majorFactionFeatureAbility = source.MajorFactionFeatureAbility
    target.majorFactionType = source.MajorFactionType
    target.mapCanvasPosition = source.MapCanvasPosition
    target.mapIconUIWidgetSetType = source.MapIconUIWidgetSetType
    target.mapOverlayDisplayLocation = source.MapOverlayDisplayLocation
    target.mapPinAnimationType = source.MapPinAnimationType
    target.mapobjEventTypes = source.MapobjEventTypes
    target.matchDetailType = source.MatchDetailType
    target.microMenuOrder = source.MicroMenuOrder
    target.microMenuOrientation = source.MicroMenuOrientation
    target.minimapTrackingFilter = source.MinimapTrackingFilter
    target.modelBlendOperation = source.ModelBlendOperation
    target.modelLightType = source.ModelLightType
    target.modelSceneSetting = source.ModelSceneSetting
    target.modelSceneType = source.ModelSceneType
    target.mountType = source.MountType
    target.mountTypeFlag = source.MountTypeFlag
    target.namePlateCastBarDisplay = source.NamePlateCastBarDisplay
    target.namePlateEnemyNpcAuraDisplay = source.NamePlateEnemyNpcAuraDisplay
    target.namePlateEnemyPlayerAuraDisplay = source.NamePlateEnemyPlayerAuraDisplay
    target.namePlateFriendlyPlayerAuraDisplay = source.NamePlateFriendlyPlayerAuraDisplay
    target.namePlateInfoDisplay = source.NamePlateInfoDisplay
    target.namePlateSimplifiedType = source.NamePlateSimplifiedType
    target.namePlateSize = source.NamePlateSize
    target.namePlateStackType = source.NamePlateStackType
    target.namePlateStyle = source.NamePlateStyle
    target.namePlateThreatDisplay = source.NamePlateThreatDisplay
    target.namePlateType = source.NamePlateType
    target.navigationState = source.NavigationState
    target.neighborhoodFlags = source.NeighborhoodFlags
    target.neighborhoodInitiativeChestResult = source.NeighborhoodInitiativeChestResult
    target.neighborhoodInitiativeFlags = source.NeighborhoodInitiativeFlags
    target.neighborhoodInitiativeNeighborhoodTypes = source.NeighborhoodInitiativeNeighborhoodTypes
    target.neighborhoodInitiativeTaskType = source.NeighborhoodInitiativeTaskType
    target.neighborhoodInitiativeUpdateStatus = source.NeighborhoodInitiativeUpdateStatus
    target.neighborhoodInitiativesCompletionStates = source.NeighborhoodInitiativesCompletionStates
    target.neighborhoodInviteResult = source.NeighborhoodInviteResult
    target.neighborhoodMapFlags = source.NeighborhoodMapFlags
    target.newCharGear = source.NewCharGear
    target.noRPEReason = source.NoRPEReason
    target.nodeOpFailureReason = source.NodeOpFailureReason
    target.npcCraftingOrderSetFlags = source.NpcCraftingOrderSetFlags
    target.numericRuleFormatRounding = source.NumericRuleFormatRounding
    target.onUpdateMode = source.OnUpdateMode
    target.partyPoseFlags = source.PartyPoseFlags
    target.partyRequestJoinRelation = source.PartyRequestJoinRelation
    target.perksVendorCategoryType = source.PerksVendorCategoryType
    target.permanentChatChannelType = source.PermanentChatChannelType
    target.personalResourceDisplayVisibleSetting = source.PersonalResourceDisplayVisibleSetting
    target.petActionFeedback = source.PetActionFeedback
    target.petActionbuttonType = source.PetActionbuttonType
    target.petBattleQueueStatus = source.PetBattleQueueStatus
    target.petJournalError = source.PetJournalError
    target.petMode = source.PetMode
    target.petOrders = source.PetOrders
    target.petOverride = source.PetOverride
    target.petbattleSlot = source.PetbattleSlot
    target.petbattleState = source.PetbattleState
    target.pettameresult = source.Pettameresult
    target.phaseReason = source.PhaseReason
    target.photoSharingStatus = source.PhotoSharingStatus
    target.photoSharingUploadStatus = source.PhotoSharingUploadStatus
    target.pingMode = source.PingMode
    target.pingResult = source.PingResult
    target.pingSetTargetState = source.PingSetTargetState
    target.pingSubjectType = source.PingSubjectType
    target.pingTargetOption = source.PingTargetOption
    target.pingTargetType = source.PingTargetType
    target.pingTextureType = source.PingTextureType
    target.pingTypeFlags = source.PingTypeFlags
    target.playerChoiceFlags = source.PlayerChoiceFlags
    target.playerChoiceLayout = source.PlayerChoiceLayout
    target.playerChoiceRarity = source.PlayerChoiceRarity
    target.playerChoiceResponseFlags = source.PlayerChoiceResponseFlags
    target.playerClubRequestStatus = source.PlayerClubRequestStatus
    target.playerCompanionInfoFlags = source.PlayerCompanionInfoFlags
    target.playerCurrencyFlags = source.PlayerCurrencyFlags
    target.playerCurrencyFlagsDbFlags = source.PlayerCurrencyFlagsDbFlags
    target.playerDataElementType = source.PlayerDataElementType
    target.playerInteractionType = source.PlayerInteractionType
    target.playerMentorshipApplicationResult = source.PlayerMentorshipApplicationResult
    target.playerMentorshipStatus = source.PlayerMentorshipStatus
    target.plunderstormQueueState = source.PlunderstormQueueState
    target.powerType = source.PowerType
    target.powerTypeSign = source.PowerTypeSign
    target.powerTypeSlot = source.PowerTypeSlot
    target.premadeGroupFinderStyle = source.PremadeGroupFinderStyle
    target.preyHuntProgressState = source.PreyHuntProgressState
    target.proceduralSpawnInteractionMode = source.ProceduralSpawnInteractionMode
    target.proceduralSpawnVolumeChunkFlags = source.ProceduralSpawnVolumeChunkFlags
    target.profTraitPerkNodeFlags = source.ProfTraitPerkNodeFlags
    target.profession = source.Profession
    target.professionActionType = source.ProfessionActionType
    target.professionEffect = source.ProfessionEffect
    target.professionRating = source.ProfessionRating
    target.professionRatingType = source.ProfessionRatingType
    target.professionsSpecPathState = source.ProfessionsSpecPathState
    target.professionsSpecPerkState = source.ProfessionsSpecPerkState
    target.professionsSpecTabState = source.ProfessionsSpecTabState
    target.purchaseResult = source.PurchaseResult
    target.pvpFaction = source.PvPFaction
    target.pvpMatchState = source.PvPMatchState
    target.pvpMatchmakingType = source.PvPMatchmakingType
    target.pvpRanks = source.PvPRanks
    target.pvpUnitClassification = source.PvPUnitClassification
    target.questClassification = source.QuestClassification
    target.questCompleteSpellType = source.QuestCompleteSpellType
    target.questFrequency = source.QuestFrequency
    target.questLineFloorLocation = source.QuestLineFloorLocation
    target.questRepeatability = source.QuestRepeatability
    target.questRewardContextFlags = source.QuestRewardContextFlags
    target.questSessionCommand = source.QuestSessionCommand
    target.questSessionResult = source.QuestSessionResult
    target.questTag = source.QuestTag
    target.questTagType = source.QuestTagType
    target.questTreasurePickerType = source.QuestTreasurePickerType
    target.questWatchType = source.QuestWatchType
    target.rafLinkType = source.RafLinkType
    target.rafRecruitActivityState = source.RafRecruitActivityState
    target.rafRecruitSubStatus = source.RafRecruitSubStatus
    target.rafRewardType = source.RafRewardType
    target.raidAuraOrganizationType = source.RaidAuraOrganizationType
    target.raidDispelDisplayType = source.RaidDispelDisplayType
    target.raidDispelOverlayType = source.RaidDispelOverlayType
    target.raidGroupDisplayType = source.RaidGroupDisplayType
    target.rcoCloseReason = source.RcoCloseReason
    target.recentAlliesFriendTag = source.RecentAlliesFriendTag
    target.recentAllyPinResult = source.RecentAllyPinResult
    target.recipeRequirementType = source.RecipeRequirementType
    target.recruitAFriendFailure = source.RecruitAFriendFailure
    target.recruitAFriendRewardsVersion = source.RecruitAFriendRewardsVersion
    target.registerAddonMessagePrefixResult = source.RegisterAddonMessagePrefixResult
    target.relativeContentDifficulty = source.RelativeContentDifficulty
    target.releaseType = source.ReleaseType
    target.renownRewardDisplayType = source.RenownRewardDisplayType
    target.renownRewardsFlags = source.RenownRewardsFlags
    target.reportEvidenceType = source.ReportEvidenceType
    target.reportMajorCategory = source.ReportMajorCategory
    target.reportMinorCategory = source.ReportMinorCategory
    target.reportSubComplaintTypes = source.ReportSubComplaintTypes
    target.reportThrottleType = source.ReportThrottleType
    target.reportType = source.ReportType
    target.reputationSortType = source.ReputationSortType
    target.restrictPingsTo = source.RestrictPingsTo
    target.restrictionType = source.RestrictionType
    target.retroactiveDecorRewardFlags = source.RetroactiveDecorRewardFlags
    target.rolodexContactMigrationResult = source.RolodexContactMigrationResult
    target.rolodexContextLevelType = source.RolodexContextLevelType
    target.rolodexDbFlags = source.RolodexDbFlags
    target.rolodexType = source.RolodexType
    target.rolodexTypeFlags = source.RolodexTypeFlags
    target.roomConnectionType = source.RoomConnectionType
    target.runeforgePowerFilter = source.RuneforgePowerFilter
    target.runeforgePowerState = source.RuneforgePowerState
    target.screenLocationType = source.ScreenLocationType
    target.screenshotSource = source.ScreenshotSource
    target.scriptBindingType = source.ScriptBindingType
    target.scriptObjectAccessRestriction = source.ScriptObjectAccessRestriction
    target.scriptObjectMetatable = source.ScriptObjectMetatable
    target.scriptObjectPartition = source.ScriptObjectPartition
    target.scriptObjectPropagationPath = source.ScriptObjectPropagationPath
    target.scriptedAnimationBehavior = source.ScriptedAnimationBehavior
    target.scriptedAnimationFlags = source.ScriptedAnimationFlags
    target.scriptedAnimationTrajectory = source.ScriptedAnimationTrajectory
    target.scrubStringFlags = source.ScrubStringFlags
    target.seasonID = source.SeasonID
    target.secondsFormatterAbbreviation = source.SecondsFormatterAbbreviation
    target.secondsFormatterInterval = source.SecondsFormatterInterval
    target.secondsFormatterIntervalWhitespace = source.SecondsFormatterIntervalWhitespace
    target.secondsFormatterRounding = source.SecondsFormatterRounding
    target.secrecyLevel = source.SecrecyLevel
    target.secretAspect = source.SecretAspect
    target.selfResurrectOptionType = source.SelfResurrectOptionType
    target.sendAddonMessageResult = source.SendAddonMessageResult
    target.sendReportResult = source.SendReportResult
    target.sharedStringFlag = source.SharedStringFlag
    target.simpleOrderStatus = source.SimpleOrderStatus
    target.skinningState = source.SkinningState
    target.sleevesGeoRange = source.SleevesGeoRange
    target.slotRegion = source.SlotRegion
    target.slotRegionMask = source.SlotRegionMask
    target.socialSystemType = source.SocialSystemType
    target.socialUIBlockType = source.SocialUIBlockType
    target.socialUIPresenceType = source.SocialUIPresenceType
    target.socialWhoOrigin = source.SocialWhoOrigin
    target.softTargetEnableFlags = source.SoftTargetEnableFlags
    target.sortPlayersBy = source.SortPlayersBy
    target.soulbindConduitFlags = source.SoulbindConduitFlags
    target.soulbindConduitInstallResult = source.SoulbindConduitInstallResult
    target.soulbindConduitTransactionType = source.SoulbindConduitTransactionType
    target.soulbindConduitType = source.SoulbindConduitType
    target.soulbindNodeState = source.SoulbindNodeState
    target.specializationSystem = source.SpecializationSystem
    target.spellAuraVisibilityType = source.SpellAuraVisibilityType
    target.spellBookItemType = source.SpellBookItemType
    target.spellBookSkillLineIndex = source.SpellBookSkillLineIndex
    target.spellBookSpellBank = source.SpellBookSpellBank
    target.spellDiminishCategory = source.SpellDiminishCategory
    target.spellDiminishRuleset = source.SpellDiminishRuleset
    target.spellDisplayBorderColor = source.SpellDisplayBorderColor
    target.spellDisplayIconDisplayType = source.SpellDisplayIconDisplayType
    target.spellDisplayTextShownStateType = source.SpellDisplayTextShownStateType
    target.spellDisplayTint = source.SpellDisplayTint
    target.splashScreenType = source.SplashScreenType
    target.stableResult = source.StableResult
    target.startTimerType = source.StartTimerType
    target.statusBarColorTintValue = source.StatusBarColorTintValue
    target.statusBarFillStyle = source.StatusBarFillStyle
    target.statusBarInterpolation = source.StatusBarInterpolation
    target.statusBarOverrideBarTextShownType = source.StatusBarOverrideBarTextShownType
    target.statusBarRenderMode = source.StatusBarRenderMode
    target.statusBarTimerDirection = source.StatusBarTimerDirection
    target.statusBarValueTextType = source.StatusBarValueTextType
    target.subcontainerType = source.SubcontainerType
    target.subscriptionInterstitialResponseType = source.SubscriptionInterstitialResponseType
    target.subscriptionInterstitialType = source.SubscriptionInterstitialType
    target.summonReason = source.SummonReason
    target.summonStatus = source.SummonStatus
    target.superTrackingMapPinType = source.SuperTrackingMapPinType
    target.superTrackingType = source.SuperTrackingType
    target.surveyDeliveryFlags = source.SurveyDeliveryFlags
    target.surveyDeliveryMoment = source.SurveyDeliveryMoment
    target.tableSecurityOption = source.TableSecurityOption
    target.tieredEntranceRewardType = source.TieredEntranceRewardType
    target.tieredEntranceTierFlag = source.TieredEntranceTierFlag
    target.tieredEntranceType = source.TieredEntranceType
    target.timeEventFlag = source.TimeEventFlag
    target.titleIconVersion = source.TitleIconVersion
    target.tooltipComparisonMethod = source.TooltipComparisonMethod
    target.tooltipDataItemBinding = source.TooltipDataItemBinding
    target.tooltipDataLineType = source.TooltipDataLineType
    target.tooltipDataType = source.TooltipDataType
    target.tooltipDataUsageRequirementType = source.TooltipDataUsageRequirementType
    target.tooltipSide = source.TooltipSide
    target.tooltipTextureAnchor = source.TooltipTextureAnchor
    target.tooltipTextureRelativeRegion = source.TooltipTextureRelativeRegion
    target.trackedSpellCategory = source.TrackedSpellCategory
    target.trackedSpellsResult = source.TrackedSpellsResult
    target.tradeskillOrderDuration = source.TradeskillOrderDuration
    target.tradeskillOrderRecipient = source.TradeskillOrderRecipient
    target.tradeskillOrderStatus = source.TradeskillOrderStatus
    target.tradeskillRecipeType = source.TradeskillRecipeType
    target.tradeskillRelativeDifficulty = source.TradeskillRelativeDifficulty
    target.tradeskillSlotDataType = source.TradeskillSlotDataType
    target.traitCombatConfigFlags = source.TraitCombatConfigFlags
    target.traitCondFlag = source.TraitCondFlag
    target.traitConditionType = source.TraitConditionType
    target.traitConfigDbState = source.TraitConfigDbState
    target.traitConfigType = source.TraitConfigType
    target.traitCurrencyFlag = source.TraitCurrencyFlag
    target.traitCurrencyType = source.TraitCurrencyType
    target.traitDefinitionSubType = source.TraitDefinitionSubType
    target.traitEdgeType = source.TraitEdgeType
    target.traitEdgeVisualStyle = source.TraitEdgeVisualStyle
    target.traitNodeEntryType = source.TraitNodeEntryType
    target.traitNodeFlag = source.TraitNodeFlag
    target.traitNodeGroupFlag = source.TraitNodeGroupFlag
    target.traitNodeType = source.TraitNodeType
    target.traitPointsOperationType = source.TraitPointsOperationType
    target.traitSystemFlag = source.TraitSystemFlag
    target.traitSystemVariationType = source.TraitSystemVariationType
    target.traitTreeFlag = source.TraitTreeFlag
    target.transformManipulatorAxis = source.TransformManipulatorAxis
    target.transformManipulatorControlState = source.TransformManipulatorControlState
    target.transformManipulatorDirection = source.TransformManipulatorDirection
    target.transformManipulatorEvent = source.TransformManipulatorEvent
    target.transformManipulatorMode = source.TransformManipulatorMode
    target.transmogCameraVariation = source.TransmogCameraVariation
    target.transmogCollectionType = source.TransmogCollectionType
    target.transmogIllusionFlags = source.TransmogIllusionFlags
    target.transmogModification = source.TransmogModification
    target.transmogOutfitCostModifiersApplied = source.TransmogOutfitCostModifiersApplied
    target.transmogOutfitDataFlags = source.TransmogOutfitDataFlags
    target.transmogOutfitDisplayType = source.TransmogOutfitDisplayType
    target.transmogOutfitEntryFlags = source.TransmogOutfitEntryFlags
    target.transmogOutfitEntrySource = source.TransmogOutfitEntrySource
    target.transmogOutfitEquipAction = source.TransmogOutfitEquipAction
    target.transmogOutfitSetType = source.TransmogOutfitSetType
    target.transmogOutfitSlot = source.TransmogOutfitSlot
    target.transmogOutfitSlotError = source.TransmogOutfitSlotError
    target.transmogOutfitSlotFlags = source.TransmogOutfitSlotFlags
    target.transmogOutfitSlotOption = source.TransmogOutfitSlotOption
    target.transmogOutfitSlotOptionFlags = source.TransmogOutfitSlotOptionFlags
    target.transmogOutfitSlotOptionSheatheCategory = source.TransmogOutfitSlotOptionSheatheCategory
    target.transmogOutfitSlotPosition = source.TransmogOutfitSlotPosition
    target.transmogOutfitSlotSaveFlags = source.TransmogOutfitSlotSaveFlags
    target.transmogOutfitSlotWarning = source.TransmogOutfitSlotWarning
    target.transmogOutfitTransactionFlags = source.TransmogOutfitTransactionFlags
    target.transmogOutfitTransactionType = source.TransmogOutfitTransactionType
    target.transmogPendingType = source.TransmogPendingType
    target.transmogSearchType = source.TransmogSearchType
    target.transmogSituation = source.TransmogSituation
    target.transmogSituationFlags = source.TransmogSituationFlags
    target.transmogSituationGroupFlags = source.TransmogSituationGroupFlags
    target.transmogSituationTrigger = source.TransmogSituationTrigger
    target.transmogSituationTriggerFlags = source.TransmogSituationTriggerFlags
    target.transmogSituationTriggerType = source.TransmogSituationTriggerType
    target.transmogSlot = source.TransmogSlot
    target.transmogSource = source.TransmogSource
    target.transmogTimeOfDayCategory = source.TransmogTimeOfDayCategory
    target.transmogType = source.TransmogType
    target.transmogUseErrorType = source.TransmogUseErrorType
    target.ttsBoolSetting = source.TtsBoolSetting
    target.ttsVoiceType = source.TtsVoiceType
    target.tugOfWarMarkerArrowShownState = source.TugOfWarMarkerArrowShownState
    target.tugOfWarStyleValue = source.TugOfWarStyleValue
    target.turnStrafeStyle = source.TurnStrafeStyle
    target.uiActionType = source.UIActionType
    target.uiCovenantDisplayInfoFlags = source.UICovenantDisplayInfoFlags
    target.uiCursorType = source.UICursorType
    target.uiFrameType = source.UIFrameType
    target.uiItemInteractionFlags = source.UIItemInteractionFlags
    target.uiItemInteractionType = source.UIItemInteractionType
    target.uiMapFlag = source.UIMapFlag
    target.uiMapGroupFlag = source.UIMapGroupFlag
    target.uiMapSystem = source.UIMapSystem
    target.uiMapType = source.UIMapType
    target.uiModelSceneActorFlag = source.UIModelSceneActorFlag
    target.uiModelSceneContext = source.UIModelSceneContext
    target.uiModelSceneFlags = source.UIModelSceneFlags
    target.uiSystemType = source.UISystemType
    target.uiTextureSliceMode = source.UITextureSliceMode
    target.uiWidgetBlendModeType = source.UIWidgetBlendModeType
    target.uiWidgetButtonEnabledState = source.UIWidgetButtonEnabledState
    target.uiWidgetButtonIconType = source.UIWidgetButtonIconType
    target.uiWidgetFlag = source.UIWidgetFlag
    target.uiWidgetFontType = source.UIWidgetFontType
    target.uiWidgetHorizontalDirection = source.UIWidgetHorizontalDirection
    target.uiWidgetLayoutDirection = source.UIWidgetLayoutDirection
    target.uiWidgetModelSceneLayer = source.UIWidgetModelSceneLayer
    target.uiWidgetMotionType = source.UIWidgetMotionType
    target.uiWidgetOverrideState = source.UIWidgetOverrideState
    target.uiWidgetRewardShownState = source.UIWidgetRewardShownState
    target.uiWidgetScale = source.UIWidgetScale
    target.uiWidgetSetLayoutDirection = source.UIWidgetSetLayoutDirection
    target.uiWidgetSpellButtonCooldownType = source.UIWidgetSpellButtonCooldownType
    target.uiWidgetTextFormatType = source.UIWidgetTextFormatType
    target.uiWidgetTextSizeType = source.UIWidgetTextSizeType
    target.uiWidgetTextureAndTextSizeType = source.UIWidgetTextureAndTextSizeType
    target.uiWidgetTooltipLocation = source.UIWidgetTooltipLocation
    target.uiWidgetUpdateAnimType = source.UIWidgetUpdateAnimType
    target.uiWidgetVisualizationType = source.UIWidgetVisualizationType
    target.unitAuraSortDirection = source.UnitAuraSortDirection
    target.unitAuraSortRule = source.UnitAuraSortRule
    target.unitAuraSoundTrigger = source.UnitAuraSoundTrigger
    target.unitDamageAbsorbClampMode = source.UnitDamageAbsorbClampMode
    target.unitHealAbsorbClampMode = source.UnitHealAbsorbClampMode
    target.unitHealAbsorbMode = source.UnitHealAbsorbMode
    target.unitIncomingHealClampMode = source.UnitIncomingHealClampMode
    target.unitMaximumHealthMode = source.UnitMaximumHealthMode
    target.unitMirrorPetFlags = source.UnitMirrorPetFlags
    target.unitSex = source.UnitSex
    target.unitTokenType = source.UnitTokenType
    target.urlTextureResult = source.UrlTextureResult
    target.validateNameResult = source.ValidateNameResult
    target.vasTransactionPurchaseResult = source.VasTransactionPurchaseResult
    target.viewArenaSize = source.ViewArenaSize
    target.viewRaidSize = source.ViewRaidSize
    target.vignetteObjectiveType = source.VignetteObjectiveType
    target.vignetteType = source.VignetteType
    target.visualAlertType = source.VisualAlertType
    target.voiceChannelErrorReason = source.VoiceChannelErrorReason
    target.voiceChatStatusCode = source.VoiceChatStatusCode
    target.voiceTtsStatusCode = source.VoiceTtsStatusCode
    target.warbandEventState = source.WarbandEventState
    target.warbandGroupFlags = source.WarbandGroupFlags
    target.warbandPlacementDisplayInfoType = source.WarbandPlacementDisplayInfoType
    target.warbandSceneAnimationEvent = source.WarbandSceneAnimationEvent
    target.warbandSceneAnimationSheatheState = source.WarbandSceneAnimationSheatheState
    target.warbandSceneAnimationStandState = source.WarbandSceneAnimationStandState
    target.warbandSceneAnimationStandStateFlags = source.WarbandSceneAnimationStandStateFlags
    target.warbandSceneFlags = source.WarbandSceneFlags
    target.warbandScenePlacementType = source.WarbandScenePlacementType
    target.weaponSlot = source.WeaponSlot
    target.widgetAnimationType = source.WidgetAnimationType
    target.widgetCurrencyClass = source.WidgetCurrencyClass
    target.widgetEnabledState = source.WidgetEnabledState
    target.widgetGlowAnimType = source.WidgetGlowAnimType
    target.widgetIconSizeType = source.WidgetIconSizeType
    target.widgetIconSourceType = source.WidgetIconSourceType
    target.widgetOpacityType = source.WidgetOpacityType
    target.widgetShowGlowState = source.WidgetShowGlowState
    target.widgetShownState = source.WidgetShownState
    target.widgetTextHorizontalAlignmentType = source.WidgetTextHorizontalAlignmentType
    target.widgetUnitPowerBarFlashMomentType = source.WidgetUnitPowerBarFlashMomentType
    target.worldCursorAnchorType = source.WorldCursorAnchorType
    target.worldElapsedTimerTypes = source.WorldElapsedTimerTypes
    target.worldQuestQuality = source.WorldQuestQuality
    target.worldTierDifficulty = source.WorldTierDifficulty
    target.wowClientCursorSize = source.WoWClientCursorSize
    target.wowEntitlementType = source.WoWEntitlementType
    target.zoneControlActiveState = source.ZoneControlActiveState
    target.zoneControlDangerFlashType = source.ZoneControlDangerFlashType
    target.zoneControlFillType = source.ZoneControlFillType
    target.zoneControlLeadingEdgeType = source.ZoneControlLeadingEdgeType
    target.zoneControlMode = source.ZoneControlMode
    target.zoneControlState = source.ZoneControlState
  end
  do
    local source = host.Constants or {}
    local target = {}
    api.constants = target
    target.auctionConstants = source.AuctionConstants
    target.caaConstants = source.CAAConstants
    target.calendarGetEventTypeConstants = source.CalendarGetEventTypeConstants
    target.callings = source.Callings
    target.catalogShopVirtualCurrencyConstants = source.CatalogShopVirtualCurrencyConstants
    target.charCustomizationConstants = source.CharCustomizationConstants
    target.chatFrameConstants = source.ChatFrameConstants
    target.combatLogMessageLimits = source.CombatLogMessageLimits
    target.combatLogObjectMasks = source.CombatLogObjectMasks
    target.combatLogObjectTargetMasks = source.CombatLogObjectTargetMasks
    target.contentTrackingConsts = source.ContentTrackingConsts
    target.cooldownFrameDefaults = source.CooldownFrameDefaults
    target.cooldownViewerUIConstants = source.CooldownViewerUIConstants
    target.craftingOrderConsts = source.CraftingOrderConsts
    target.currencyConsts = source.CurrencyConsts
    target.delvesConsts = source.DelvesConsts
    target.editModeConsts = source.EditModeConsts
    target.editModeLayoutConsts = source.EditModeLayoutConsts
    target.encodingLimits = source.EncodingLimits
    target.encounterTimelineEventConstants = source.EncounterTimelineEventConstants
    target.encounterTimelineIconMasks = source.EncounterTimelineIconMasks
    target.eventScheduler = source.EventScheduler
    target.groupBuffUIConstants = source.GroupBuffUIConstants
    target.housingCatalogConsts = source.HousingCatalogConsts
    target.housingConsts = source.HousingConsts
    target.inventoryConstants = source.InventoryConstants
    target.itemConsts = source.ItemConsts
    target.itemConstsMainline = source.ItemConsts_Mainline
    target.itemWeaponSubclassConstants = source.ITEM_WEAPON_SUBCLASSConstants
    target.itemWeaponSubclassConstantsPostMists = source.ITEM_WEAPON_SUBCLASSConstants_PostMists
    target.levelConstsExposed = source.LevelConstsExposed
    target.lfgConstsExposed = source.LFGConstsExposed
    target.lfgRoleConstants = source.LFG_ROLEConstants
    target.lootConsts = source.LootConsts
    target.lossOfControlConsts = source.LossOfControlConsts
    target.macroConsts = source.MacroConsts
    target.majorFactionsConsts = source.MajorFactionsConsts
    target.moneyFormattingConstants = source.MoneyFormattingConstants
    target.mountDynamicFlightConsts = source.MountDynamicFlightConsts
    target.partyCountdownConstants = source.PartyCountdownConstants
    target.petConsts = source.PetConsts
    target.petConstsPostCata = source.PetConsts_PostCata
    target.professionConsts = source.ProfessionConsts
    target.pvpInfoConsts = source.PvpInfoConsts
    target.questWatchConsts = source.QuestWatchConsts
    target.recentAlliesConsts = source.RecentAlliesConsts
    target.spellBookSpellIDs = source.SpellBookSpellIDs
    target.spellCooldownConsts = source.SpellCooldownConsts
    target.talentConsts = source.TalentConsts
    target.talentTierConstants = source.TalentTierConstants
    target.tieredEntranceConsts = source.TieredEntranceConsts
    target.timerunningConsts = source.TimerunningConsts
    target.traitConsts = source.TraitConsts
    target.transmog = source.Transmog
    target.transmogOutfitDataConsts = source.TransmogOutfitDataConsts
    target.ttsConstants = source.TTSConstants
    target.uiCharacterClasses = source.UICharacterClasses
    target.unitAuraUIConstants = source.UnitAuraUIConstants
    target.unitEventConstants = source.UnitEventConstants
    target.unitPowerSpellIDs = source.UnitPowerSpellIDs
  end
end, { version = "12.1.0", build = 69933 })
