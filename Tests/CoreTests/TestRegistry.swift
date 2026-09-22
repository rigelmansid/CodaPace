//
//  TestRegistry.swift — 测试用例清单
//
//  新增用例后记得在这里登记一行,否则不会被执行。
//  (标准 XCTest 靠 ObjC runtime 自动发现;本机没有 XCTest,换成显式登记,
//   少一层运行时魔法,行为完全可预测。)
//

let allSuites: [TestSuite] = [

    ("TimeWindowTests", [
        ("testElapsedAndRemainingRatio", { TimeWindowTests().testElapsedAndRemainingRatio() }),
        ("testRatiosAreClampedOutsideTheWindow", { TimeWindowTests().testRatiosAreClampedOutsideTheWindow() }),
        ("testZeroDurationDoesNotDivideByZero", { TimeWindowTests().testZeroDurationDoesNotDivideByZero() }),
    ]),

    ("PaceTests", [
        ("testRealWorldWindowIsOnPace", { PaceTests().testRealWorldWindowIsOnPace() }),
        ("testOverPaceWhenQuotaDropsFasterThanTime", { PaceTests().testOverPaceWhenQuotaDropsFasterThanTime() }),
        ("testNoWindowMeansNoPaceVerdict", { PaceTests().testNoWindowMeansNoPaceVerdict() }),
        ("testUnlimitedGaugeHasNoPaceAndIsNeverCritical", { PaceTests().testUnlimitedGaugeHasNoPaceAndIsNeverCritical() }),
        ("testCriticalOutranksOverPace", { PaceTests().testCriticalOutranksOverPace() }),
        ("testRemainingAndUsedRatioAreClamped", { PaceTests().testRemainingAndUsedRatioAreClamped() }),
    ]),

    ("ResetScheduleTests", [
        ("testWindowUsesExactTimestampsWhenPresent", { ResetScheduleTests().testWindowUsesExactTimestampsWhenPresent() }),
        ("testWindowFallsBackToRemainingSeconds", { ResetScheduleTests().testWindowFallsBackToRemainingSeconds() }),
        ("testWindowIsNilWhenNoTimingDataAtAll", { ResetScheduleTests().testWindowIsNilWhenNoTimingDataAtAll() }),
        ("testWeeklyIntervalResolvesToPreviousMonday", { ResetScheduleTests().testWeeklyIntervalResolvesToPreviousMonday() }),
        ("testWeeklyIntervalIsNilWhenFieldsMissing", { ResetScheduleTests().testWeeklyIntervalIsNilWhenFieldsMissing() }),
        ("testDailyIntervalSpansLocalMidnightAndIsMarkedInferred", { ResetScheduleTests().testDailyIntervalSpansLocalMidnightAndIsMarkedInferred() }),
        ("testObservedDailyResetHourIsNotMarkedInferred", { ResetScheduleTests().testObservedDailyResetHourIsNotMarkedInferred() }),
        ("testNowExactlyOnBoundaryStartsNewWindow", { ResetScheduleTests().testNowExactlyOnBoundaryStartsNewWindow() }),
    ]),

    ("DailyResetLearnerTests", [
        ("testCounterDroppingSignalsAReset", { DailyResetLearnerTests().testCounterDroppingSignalsAReset() }),
        ("testRisingCounterIsNotAReset", { DailyResetLearnerTests().testRisingCounterIsNotAReset() }),
        ("testWideSamplingGapIsRejected", { DailyResetLearnerTests().testWideSamplingGapIsRejected() }),
        ("testResetAtNonMidnightHourIsLearned", { DailyResetLearnerTests().testResetAtNonMidnightHourIsLearned() }),
    ]),

    ("LearnedDailyResetTests", [
        ("testRecordOnlyAppliesInTheZoneItWasLearnedIn", { LearnedDailyResetTests().testRecordOnlyAppliesInTheZoneItWasLearnedIn() }),
        ("testFirstObservationIsAdopted", { LearnedDailyResetTests().testFirstObservationIsAdopted() }),
        ("testSameHourNeedsNoWrite", { LearnedDailyResetTests().testSameHourNeedsNoWrite() }),
        ("testContradictingObservationUpdatesTheRule", { LearnedDailyResetTests().testContradictingObservationUpdatesTheRule() }),
        ("testTimeZoneChangeDiscardsTheOldRule", { LearnedDailyResetTests().testTimeZoneChangeDiscardsTheOldRule() }),
        ("testUnknownRuleKeepsTheInferredMarker", { LearnedDailyResetTests().testUnknownRuleKeepsTheInferredMarker() }),
    ]),

    ("AccountKeyScopeTests", [
        ("testStorageKeyIgnoresTheEndpoint", { AccountKeyScopeTests().testStorageKeyIgnoresTheEndpoint() }),
        ("testPreferenceKeyDistinguishesTheEndpoint", { AccountKeyScopeTests().testPreferenceKeyDistinguishesTheEndpoint() }),
        ("testPreferenceKeyDistinguishesTheAccount", { AccountKeyScopeTests().testPreferenceKeyDistinguishesTheAccount() }),
        ("testNeitherKeyLeaksRawCredentials", { AccountKeyScopeTests().testNeitherKeyLeaksRawCredentials() }),
        ("testSinglePartDeriveMatchesTheLegacyAccountKey", { AccountKeyScopeTests().testSinglePartDeriveMatchesTheLegacyAccountKey() }),
        ("testMultiPartDeriveHasNoConcatenationAmbiguity", { AccountKeyScopeTests().testMultiPartDeriveHasNoConcatenationAmbiguity() }),
    ]),

    ("RelayProviderTests", [
        ("testIdentityIsStableAndNotTheDisplayName", { RelayProviderTests().testIdentityIsStableAndNotTheDisplayName() }),
        ("testDetectsTheStatsPagePath", { RelayProviderTests().testDetectsTheStatsPagePath() }),
        ("testDetectIgnoresTheDomain", { RelayProviderTests().testDetectIgnoresTheDomain() }),
        ("testDetectRejectsNonSense", { RelayProviderTests().testDetectRejectsNonSense() }),
        ("testParsesSchemeHostAndApiId", { RelayProviderTests().testParsesSchemeHostAndApiId() }),
        ("testKeepsANonStandardPort", { RelayProviderTests().testKeepsANonStandardPort() }),
        ("testMissingOrEmptyApiIdDoesNotParse", { RelayProviderTests().testMissingOrEmptyApiIdDoesNotParse() }),
        ("testSurroundingWhitespaceIsTolerated", { RelayProviderTests().testSurroundingWhitespaceIsTolerated() }),
        ("testManagementURLIsBuiltByTheAdapter", { RelayProviderTests().testManagementURLIsBuiltByTheAdapter() }),
        ("testNoManagementURLWithoutAConfiguredAccount", { RelayProviderTests().testNoManagementURLWithoutAConfiguredAccount() }),
        ("testDeclaresWhatTheRelayActuallyProvides", { RelayProviderTests().testDeclaresWhatTheRelayActuallyProvides() }),
        ("testDeclaresTheTwoThingsTheRelayDoesNotProvide", { RelayProviderTests().testDeclaresTheTwoThingsTheRelayDoesNotProvide() }),
    ]),

    ("ProviderRegistryTests", [
        ("testResolvesByProviderID", { ProviderRegistryTests().testResolvesByProviderID() }),
        ("testUnknownOrMissingProviderIDFallsBack", { ProviderRegistryTests().testUnknownOrMissingProviderIDFallsBack() }),
        ("testParseReturnsBothTheAdapterAndTheAccount", { ProviderRegistryTests().testParseReturnsBothTheAdapterAndTheAccount() }),
        ("testUnparsableInputResolvesToNothing", { ProviderRegistryTests().testUnparsableInputResolvesToNothing() }),
        ("testCandidatesAreFilteredByDetect", { ProviderRegistryTests().testCandidatesAreFilteredByDetect() }),
    ]),

    ("ProviderScopedIdentityTests", [
        ("testProviderIDIsPartOfTheIdentity", { ProviderScopedIdentityTests().testProviderIDIsPartOfTheIdentity() }),
        ("testStorageAndPreferenceKeysDeliberatelyIgnoreTheProvider", { ProviderScopedIdentityTests().testStorageAndPreferenceKeysDeliberatelyIgnoreTheProvider() }),
    ]),

    ("PathPrefixTests", [
        ("testSubPathDeploymentKeepsItsPrefix", { PathPrefixTests().testSubPathDeploymentKeepsItsPrefix() }),
        ("testMultiSegmentPrefixIsKept", { PathPrefixTests().testMultiSegmentPrefixIsKept() }),
        ("testRootDeploymentHasNoPrefix", { PathPrefixTests().testRootDeploymentHasNoPrefix() }),
        ("testPrefixSurvivesAlongsideAPort", { PathPrefixTests().testPrefixSurvivesAlongsideAPort() }),
        ("testManagementURLRoundTripsThePrefix", { PathPrefixTests().testManagementURLRoundTripsThePrefix() }),
    ]),

    ("ProviderResolutionTests", [
        ("testKnownLinkResolves", { ProviderResolutionTests().testKnownLinkResolves() }),
        ("testUnknownLinkIsUnsupportedNotGuessed", { ProviderResolutionTests().testUnknownLinkIsUnsupportedNotGuessed() }),
        ("testManuallyChosenProviderIsHonoured", { ProviderResolutionTests().testManuallyChosenProviderIsHonoured() }),
        ("testManuallyChosenProviderThatCannotParseIsUnsupported", { ProviderResolutionTests().testManuallyChosenProviderThatCannotParseIsUnsupported() }),
    ]),

    ("CredentialSensitivityTests", [
        ("testRelayIdentifierMayBeStoredInPlainText", { CredentialSensitivityTests().testRelayIdentifierMayBeStoredInPlainText() }),
        ("testSecretBearingAdapterMayNotReusePlainTextStorage", { CredentialSensitivityTests().testSecretBearingAdapterMayNotReusePlainTextStorage() }),
    ]),

    ("ConnectionReportTests", [
        ("testAccountFactsComeFromTheResponse", { ConnectionReportTests().testAccountFactsComeFromTheResponse() }),
        ("testNoLimitedQuotaIsReported", { ConnectionReportTests().testNoLimitedQuotaIsReported() }),
        ("testIncompleteUsageIsReported", { ConnectionReportTests().testIncompleteUsageIsReported() }),
        ("testNoResetWindowIsReported", { ConnectionReportTests().testNoResetWindowIsReported() }),
        ("testMissingCapabilitiesBecomeFindings", { ConnectionReportTests().testMissingCapabilitiesBecomeFindings() }),
        ("testDeclaredCapabilitiesProduceNoSuchFindings", { ConnectionReportTests().testDeclaredCapabilitiesProduceNoSuchFindings() }),
        ("testRelayReportsItsTwoKnownLimitations", { ConnectionReportTests().testRelayReportsItsTwoKnownLimitations() }),
    ]),

    ("InFlightGateTests", [
        ("testIdleGateIsNotBusy", { InFlightGateTests().testIdleGateIsNotBusy() }),
        ("testSameTokenDoesNotReenter", { InFlightGateTests().testSameTokenDoesNotReenter() }),
        ("testDifferentTokenIsLetThrough", { InFlightGateTests().testDifferentTokenIsLetThrough() }),
        ("testStaleFinishDoesNotClearTheNewerToken", { InFlightGateTests().testStaleFinishDoesNotClearTheNewerToken() }),
    ]),

    ("CalendarDailyTests", [
        ("testPeriodStartsAtTheConfiguredLocalHour", { CalendarDailyTests().testPeriodStartsAtTheConfiguredLocalHour() }),
        ("testNonIntegerHourResetTime", { CalendarDailyTests().testNonIntegerHourResetTime() }),
        ("testMomentExactlyOnTheBoundaryStartsTheNewPeriod", { CalendarDailyTests().testMomentExactlyOnTheBoundaryStartsTheNewPeriod() }),
    ]),

    ("DaylightSavingTests", [
        ("testSpringForwardDayIsTwentyThreeHoursButStillStartsAtMidnight", { DaylightSavingTests().testSpringForwardDayIsTwentyThreeHoursButStillStartsAtMidnight() }),
        ("testFallBackDayIsTwentyFiveHoursButStillStartsAtMidnight", { DaylightSavingTests().testFallBackDayIsTwentyFiveHoursButStillStartsAtMidnight() }),
        ("testSteppingBackAcrossTheTransitionKeepsTheLocalHour", { DaylightSavingTests().testSteppingBackAcrossTheTransitionKeepsTheLocalHour() }),
        ("testCalendarAndFixedDurationDivergeAfterTheTransition", { DaylightSavingTests().testCalendarAndFixedDurationDivergeAfterTheTransition() }),
        ("testFixedDurationKeepsItsExactLengthAcrossTheTransition", { DaylightSavingTests().testFixedDurationKeepsItsExactLengthAcrossTheTransition() }),
    ]),

    ("ResetTimeZoneTests", [
        ("testSameLocalHourInAnotherZoneIsADifferentInstant", { ResetTimeZoneTests().testSameLocalHourInAnotherZoneIsADifferentInstant() }),
    ]),

    ("CalendarWeeklyTests", [
        ("testWeeklyPeriodSpansSevenDays", { CalendarWeeklyTests().testWeeklyPeriodSpansSevenDays() }),
        ("testInvalidWeekdayHasNoPeriod", { CalendarWeeklyTests().testInvalidWeekdayHasNoPeriod() }),
    ]),

    ("SubscriptionAnniversaryTests", [
        ("testMonthlyPeriodFollowsTheCalendarNotThirtyDays", { SubscriptionAnniversaryTests().testMonthlyPeriodFollowsTheCalendarNotThirtyDays() }),
        ("testBeforeTheAnniversaryBelongsToThePreviousMonth", { SubscriptionAnniversaryTests().testBeforeTheAnniversaryBelongsToThePreviousMonth() }),
        ("testDayIsClampedToShortMonths", { SubscriptionAnniversaryTests().testDayIsClampedToShortMonths() }),
        ("testClampedAnniversaryHasNotHappenedYetEarlierInTheMonth", { SubscriptionAnniversaryTests().testClampedAnniversaryHasNotHappenedYetEarlierInTheMonth() }),
        ("testInvalidDayHasNoPeriod", { SubscriptionAnniversaryTests().testInvalidDayHasNoPeriod() }),
    ]),

    ("UncomputablePeriodTests", [
        ("testRollingWindowHasNoPeriodAndNoCountdown", { UncomputablePeriodTests().testRollingWindowHasNoPeriodAndNoCountdown() }),
        ("testUnknownProducesNoFabricatedPeriod", { UncomputablePeriodTests().testUnknownProducesNoFabricatedPeriod() }),
        ("testServerProvidedIsNotExtrapolated", { UncomputablePeriodTests().testServerProvidedIsNotExtrapolated() }),
    ]),

    ("PeriodIdentityTests", [
        ("testPeriodIDIsStableAcrossMomentsInTheSamePeriod", { PeriodIdentityTests().testPeriodIDIsStableAcrossMomentsInTheSamePeriod() }),
        ("testDifferentPeriodsHaveDifferentIDs", { PeriodIdentityTests().testDifferentPeriodsHaveDifferentIDs() }),
        ("testDifferentPoliciesDoNotCollide", { PeriodIdentityTests().testDifferentPoliciesDoNotCollide() }),
        ("testProvenanceDecidesTheInferredLabel", { PeriodIdentityTests().testProvenanceDecidesTheInferredLabel() }),
        ("testProvenanceOrdering", { PeriodIdentityTests().testProvenanceOrdering() }),
    ]),

    ("ExpiredWindowPaceTests", [
        ("testInsideTheWindowStillGivesAVerdict", { ExpiredWindowPaceTests().testInsideTheWindowStillGivesAVerdict() }),
        ("testExpiredWindowGivesNoVerdict", { ExpiredWindowPaceTests().testExpiredWindowGivesNoVerdict() }),
        ("testTheEndInstantIsAlreadyOutside", { ExpiredWindowPaceTests().testTheEndInstantIsAlreadyOutside() }),
        ("testBeforeTheWindowGivesNoVerdict", { ExpiredWindowPaceTests().testBeforeTheWindowGivesNoVerdict() }),
        ("testExpiredWindowStillReportsCriticalOnQuotaAlone", { ExpiredWindowPaceTests().testExpiredWindowStillReportsCriticalOnQuotaAlone() }),
    ]),

    ("AlertLedgerAccountScopeTests", [
        ("testTwoAccountsAlertIndependentlyInTheSameCycle", { AlertLedgerAccountScopeTests().testTwoAccountsAlertIndependentlyInTheSameCycle() }),
        ("testSwitchingBackKeepsTheOriginalAccountsRecords", { AlertLedgerAccountScopeTests().testSwitchingBackKeepsTheOriginalAccountsRecords() }),
        ("testRecordsFromAnotherAccountDoNotSilenceThisOne", { AlertLedgerAccountScopeTests().testRecordsFromAnotherAccountDoNotSilenceThisOne() }),
        ("testNamespaceCoversTheWholeIdentity", { AlertLedgerAccountScopeTests().testNamespaceCoversTheWholeIdentity() }),
        ("testNamespaceDoesNotLeakRawCredentials", { AlertLedgerAccountScopeTests().testNamespaceDoesNotLeakRawCredentials() }),
    ]),

    ("AlertLedgerDeliveryTests", [
        ("testConfirmedAlertIsNotSentAgain", { AlertLedgerDeliveryTests().testConfirmedAlertIsNotSentAgain() }),
        ("testAbandonedAlertLeavesNoRecordAndCanRetry", { AlertLedgerDeliveryTests().testAbandonedAlertLeavesNoRecordAndCanRetry() }),
        ("testRetryAfterFailureCanSucceed", { AlertLedgerDeliveryTests().testRetryAfterFailureCanSucceed() }),
        ("testInFlightAlertIsNotSubmittedTwice", { AlertLedgerDeliveryTests().testInFlightAlertIsNotSubmittedTwice() }),
        ("testInFlightStateIsNotPersisted", { AlertLedgerDeliveryTests().testInFlightStateIsNotPersisted() }),
        ("testConfirmIsIdempotent", { AlertLedgerDeliveryTests().testConfirmIsIdempotent() }),
        ("testClearAllowsAlertingAgain", { AlertLedgerDeliveryTests().testClearAllowsAlertingAgain() }),
        ("testLedgerIsCappedAndDropsTheOldest", { AlertLedgerDeliveryTests().testLedgerIsCappedAndDropsTheOldest() }),
        ("testLoadingMoreThanCapacityIsTrimmed", { AlertLedgerDeliveryTests().testLoadingMoreThanCapacityIsTrimmed() }),
    ]),

    ("HistoricalLimitTests", [
        ("testRaisingTheLimitDoesNotRewriteOlderPoints", { HistoricalLimitTests().testRaisingTheLimitDoesNotRewriteOlderPoints() }),
        ("testLoweringTheLimitDoesNotRewriteOlderPoints", { HistoricalLimitTests().testLoweringTheLimitDoesNotRewriteOlderPoints() }),
        ("testRemovingTheLimitOnlyDropsThePointsAfterIt", { HistoricalLimitTests().testRemovingTheLimitOnlyDropsThePointsAfterIt() }),
        ("testLegacySamplesWithoutRecordedLimitsAreSkipped", { HistoricalLimitTests().testLegacySamplesWithoutRecordedLimitsAreSkipped() }),
        ("testAllLegacySamplesProduceNoCurve", { HistoricalLimitTests().testAllLegacySamplesProduceNoCurve() }),
        ("testSkippedSamplesDoNotCorruptSegmentNumbering", { HistoricalLimitTests().testSkippedSamplesDoNotCorruptSegmentNumbering() }),
        ("testChangingOnlyTheLimitIsNotAUsageChange", { HistoricalLimitTests().testChangingOnlyTheLimitIsNotAUsageChange() }),
        ("testAnEmptyCurveDoesNotRevealWhyItIsEmpty", { HistoricalLimitTests().testAnEmptyCurveDoesNotRevealWhyItIsEmpty() }),
        ("testAPartialCurveDoesNotRevealWhatItSkipped", { HistoricalLimitTests().testAPartialCurveDoesNotRevealWhatItSkipped() }),
    ]),

    ("SchemaMigrationTests", [
        ("testLimitsRoundTrip", { SchemaMigrationTests().testLimitsRoundTrip() }),
        ("testZeroLimitIsDistinctFromUnknown", { SchemaMigrationTests().testZeroLimitIsDistinctFromUnknown() }),
        ("testUpgradingFromV1LeavesOldRowsUnknown", { SchemaMigrationTests().testUpgradingFromV1LeavesOldRowsUnknown() }),
        ("testReopeningAnAlreadyMigratedStoreIsFine", { SchemaMigrationTests().testReopeningAnAlreadyMigratedStoreIsFine() }),
    ]),

    ("PeriodBasedSplitTests", [
        ("testCrossingAPeriodIsDetectedEvenWithoutACounterDrop", { PeriodBasedSplitTests().testCrossingAPeriodIsDetectedEvenWithoutACounterDrop() }),
        ("testWithoutARuleTheSilentResetIsInvisible", { PeriodBasedSplitTests().testWithoutARuleTheSilentResetIsInvisible() }),
        ("testCounterDropStillSplitsWithinOnePeriod", { PeriodBasedSplitTests().testCounterDropStillSplitsWithinOnePeriod() }),
        ("testSamePeriodStaysOneSegment", { PeriodBasedSplitTests().testSamePeriodStaysOneSegment() }),
        ("testNonIntegerHourResetSplitsAtTheRightMoment", { PeriodBasedSplitTests().testNonIntegerHourResetSplitsAtTheRightMoment() }),
        ("testRollingWindowRuleDoesNotSplit", { PeriodBasedSplitTests().testRollingWindowRuleDoesNotSplit() }),
    ]),

    ("ConnectorAlignmentTests", [
        ("testConnectorsUseTheRightPointsWhenSomeSamplesAreSkipped", { ConnectorAlignmentTests().testConnectorsUseTheRightPointsWhenSomeSamplesAreSkipped() }),
        ("testNoGapConnectorWhenThePreviousSampleIsNotDrawn", { ConnectorAlignmentTests().testNoGapConnectorWhenThePreviousSampleIsNotDrawn() }),
    ]),

    ("TokenAttributionTests", [
        ("testSameDayIsAttributedToThatDay", { TokenAttributionTests().testSameDayIsAttributedToThatDay() }),
        ("testWideGapIsNotAttributedToAnyDay", { TokenAttributionTests().testWideGapIsNotAttributedToAnyDay() }),
        ("testLongGapWithinOneDayIsAlsoUnattributable", { TokenAttributionTests().testLongGapWithinOneDayIsAlsoUnattributable() }),
        ("testCrossingMidnightIsNotAttributedToEitherDay", { TokenAttributionTests().testCrossingMidnightIsNotAttributedToEitherDay() }),
        ("testAttributionFollowsTheGivenTimeZone", { TokenAttributionTests().testAttributionFollowsTheGivenTimeZone() }),
    ]),

    ("UnattributedStorageTests", [
        ("testSameDayDeltaGoesIntoTheDayBucket", { UnattributedStorageTests().testSameDayDeltaGoesIntoTheDayBucket() }),
        ("testMidnightDeltaLandsInUnattributedNotInADay", { UnattributedStorageTests().testMidnightDeltaLandsInUnattributedNotInADay() }),
        ("testAttributionResumesAfterMidnight", { UnattributedStorageTests().testAttributionResumesAfterMidnight() }),
        ("testNothingIsLostAcrossTheBoundary", { UnattributedStorageTests().testNothingIsLostAcrossTheBoundary() }),
    ]),

    ("PointSelectionTests", [
        ("testEmptyChartHasNoSelection", { PointSelectionTests().testEmptyChartHasNoSelection() }),
        ("testSinglePointIsAlwaysSelected", { PointSelectionTests().testSinglePointIsAlwaysSelected() }),
        ("testExactHitHasZeroDistance", { PointSelectionTests().testExactHitHasZeroDistance() }),
        ("testSnapsToTheNearerNeighbour", { PointSelectionTests().testSnapsToTheNearerNeighbour() }),
        ("testBeforeFirstAndAfterLastStillSelect", { PointSelectionTests().testBeforeFirstAndAfterLastStillSelect() }),
        ("testTiesResolveToTheEarlierPoint", { PointSelectionTests().testTiesResolveToTheEarlierPoint() }),
        ("testDenseSamplesSelectPrecisely", { PointSelectionTests().testDenseSamplesSelectPrecisely() }),
        ("testInsideAGapReturnsARealSampleMarkedAsNearest", { PointSelectionTests().testInsideAGapReturnsARealSampleMarkedAsNearest() }),
        ("testUndrawableSamplesAreNotSelectable", { PointSelectionTests().testUndrawableSamplesAreNotSelectable() }),
    ]),

    ("QuotaTooltipTests", [
        ("testRemainingAmountUsesTheSampleOwnLimit", { QuotaTooltipTests().testRemainingAmountUsesTheSampleOwnLimit() }),
        ("testExactHitIsNotMarkedAsNearest", { QuotaTooltipTests().testExactHitIsNotMarkedAsNearest() }),
        ("testGapHitIsMarkedAsNearestWithItsRealTime", { QuotaTooltipTests().testGapHitIsMarkedAsNearestWithItsRealTime() }),
        ("testCarriesThePeriodThePointBelongsTo", { QuotaTooltipTests().testCarriesThePeriodThePointBelongsTo() }),
        ("testNoPeriodWhenTheRuleCannotComputeOne", { QuotaTooltipTests().testNoPeriodWhenTheRuleCannotComputeOne() }),
    ]),

    ("TokenTooltipTests", [
        ("testMissingDayHasNoBar", { TokenTooltipTests().testMissingDayHasNoBar() }),
        ("testGenuineZeroDayIsStillSelectable", { TokenTooltipTests().testGenuineZeroDayIsStillSelectable() }),
        ("testAnyMomentWithinTheDayHitsThatBar", { TokenTooltipTests().testAnyMomentWithinTheDayHitsThatBar() }),
        ("testCrossMonthBarsAreSelectedCorrectly", { TokenTooltipTests().testCrossMonthBarsAreSelectedCorrectly() }),
        ("testZeroRequestsAreOmittedRatherThanShownAsZero", { TokenTooltipTests().testZeroRequestsAreOmittedRatherThanShownAsZero() }),
        ("testUnattributedUsageIsCarried", { TokenTooltipTests().testUnattributedUsageIsCarried() }),
        ("testCalendarDaySpanIsAWholeDay", { TokenTooltipTests().testCalendarDaySpanIsAWholeDay() }),
        ("testNonMidnightPeriodIsNotAWholeDay", { TokenTooltipTests().testNonMidnightPeriodIsNotAWholeDay() }),
        ("testMultiDayPeriodIsNotAWholeDay", { TokenTooltipTests().testMultiDayPeriodIsNotAWholeDay() }),
    ]),

    ("ExactNumberTests", [
        ("testExactKeepsEveryDigitWithGrouping", { ExactNumberTests().testExactKeepsEveryDigitWithGrouping() }),
        ("testExactRoundsFractions", { ExactNumberTests().testExactRoundsFractions() }),
        ("testCompactStillAbbreviates", { ExactNumberTests().testCompactStillAbbreviates() }),
    ]),

    ("InferredBoundaryTests", [
        ("testServerProvidedBoundaryIsNotMarkedInferred", { InferredBoundaryTests().testServerProvidedBoundaryIsNotMarkedInferred() }),
        ("testInferredBoundaryIsMarked", { InferredBoundaryTests().testInferredBoundaryIsMarked() }),
        ("testObservedBoundaryCountsAsKnown", { InferredBoundaryTests().testObservedBoundaryCountsAsKnown() }),
        ("testGapConnectorIsNeverMarkedAsInferredBoundary", { InferredBoundaryTests().testGapConnectorIsNeverMarkedAsInferredBoundary() }),
    ]),

    ("DecodingTests", [
        ("testMissingFieldsFallBackToZero", { DecodingTests().testMissingFieldsFallBackToZero() }),
        ("testNullValuesFallBackToZero", { DecodingTests().testNullValuesFallBackToZero() }),
        ("testMissingWeeklyResetIsMinusOneNotZero", { DecodingTests().testMissingWeeklyResetIsMinusOneNotZero() }),
        ("testDecodesRealResponseShape", { DecodingTests().testDecodesRealResponseShape() }),
        ("testMissingUsageBlockDoesNotFail", { DecodingTests().testMissingUsageBlockDoesNotFail() }),
    ]),

    ("EnvelopeTests", [
        ("testUnwrapsSuccessfulPayload", { EnvelopeTests().testUnwrapsSuccessfulPayload() }),
        ("testSuccessFalseSurfacesServerMessage", { EnvelopeTests().testSuccessFalseSurfacesServerMessage() }),
        ("testGarbageResponseGivesAReadableError", { EnvelopeTests().testGarbageResponseGivesAReadableError() }),
    ]),

    ("FormatTests", [
        ("testMoneyShedsDecimalsAsNumbersGrow", { FormatTests().testMoneyShedsDecimalsAsNumbersGrow() }),
        ("testMoneyThresholds", { FormatTests().testMoneyThresholds() }),
        ("testMoney2AlwaysGroupsAndKeepsTwoDecimals", { FormatTests().testMoney2AlwaysGroupsAndKeepsTwoDecimals() }),
        ("testCountUsesCompactUnitsNotScientificNotation", { FormatTests().testCountUsesCompactUnitsNotScientificNotation() }),
        ("testIntGrouping", { FormatTests().testIntGrouping() }),
        ("testPercentRounds", { FormatTests().testPercentRounds() }),
        ("testDurationKeepsTwoMagnitudes", { FormatTests().testDurationKeepsTwoMagnitudes() }),
        ("testExactMagnitudesDropTheEmptyRemainder", { FormatTests().testExactMagnitudesDropTheEmptyRemainder() }),
        ("testDurationIsLocalised", { FormatTests().testDurationIsLocalised() }),
        ("testResetsIn", { FormatTests().testResetsIn() }),
    ]),

    ("MenuBarSourceTests", [
        ("testAutoPicksTightestExcludingWindow", { MenuBarSourceTests().testAutoPicksTightestExcludingWindow() }),
        ("testWindowIsNormallyIgnoredEvenWhenItIsTheTightest", { MenuBarSourceTests().testWindowIsNormallyIgnoredEvenWhenItIsTheTightest() }),
        ("testCriticalWindowTakesOver", { MenuBarSourceTests().testCriticalWindowTakesOver() }),
        ("testALongCycleIsNotAvoidedEvenThoughItHasAWindow",
         { MenuBarSourceTests().testALongCycleIsNotAvoidedEvenThoughItHasAWindow() }),
        ("testFixedSelectionIsHonoured", { MenuBarSourceTests().testFixedSelectionIsHonoured() }),
        ("testFixedSelectionFallsBackWhenUnlimited", { MenuBarSourceTests().testFixedSelectionFallsBackWhenUnlimited() }),
    ]),

    ("RelaySnapshotMappingTests", [
        ("testBuildsFourGaugesInDisplayOrder", { RelaySnapshotMappingTests().testBuildsFourGaugesInDisplayOrder() }),
        ("testTotalGaugeNeverGetsAWindow", { RelaySnapshotMappingTests().testTotalGaugeNeverGetsAWindow() }),
        ("testEmptyNameFallsBackToPlaceholder", { RelaySnapshotMappingTests().testEmptyNameFallsBackToPlaceholder() }),
    ]),

    ("SamplingPolicyTests", [
        ("testFirstSampleIsAlwaysRecorded", { SamplingPolicyTests().testFirstSampleIsAlwaysRecorded() }),
        ("testChangedValuesAreRecorded", { SamplingPolicyTests().testChangedValuesAreRecorded() }),
        ("testUnchangedWithinAnchorIntervalIsSkipped", { SamplingPolicyTests().testUnchangedWithinAnchorIntervalIsSkipped() }),
        ("testUnchangedPastAnchorIntervalIsRecorded", { SamplingPolicyTests().testUnchangedPastAnchorIntervalIsRecorded() }),
    ]),

    ("SamplingLedgerTests", [
        ("testFirstSampleIsAlwaysStored", { SamplingLedgerTests().testFirstSampleIsAlwaysStored() }),
        ("testInitFromStoreSeedsBothBaselines", { SamplingLedgerTests().testInitFromStoreSeedsBothBaselines() }),
        ("testUnstoredSampleAdvancesOnlyTheObservedBaseline", { SamplingLedgerTests().testUnstoredSampleAdvancesOnlyTheObservedBaseline() }),
        ("testIdleHourLeavesFiveAnchors", { SamplingLedgerTests().testIdleHourLeavesFiveAnchors() }),
        ("testIdleHourAccumulatesNoTokens", { SamplingLedgerTests().testIdleHourAccumulatesNoTokens() }),
        ("testChangedValueIsStoredImmediately", { SamplingLedgerTests().testChangedValueIsStoredImmediately() }),
        ("testAnchorClockRestartsFromTheLastStoredSample", { SamplingLedgerTests().testAnchorClockRestartsFromTheLastStoredSample() }),
        ("testTokenDeltaIsNeitherLostNorDoubleCountedAcrossUnstoredRefreshes", { SamplingLedgerTests().testTokenDeltaIsNeitherLostNorDoubleCountedAcrossUnstoredRefreshes() }),
        ("testContinuouslyChangingValuesAreStoredEveryRefresh", { SamplingLedgerTests().testContinuouslyChangingValuesAreStoredEveryRefresh() }),
    ]),

    ("TokenDeltaTests", [
        ("testNoPreviousMeansBaselineOnly", { TokenDeltaTests().testNoPreviousMeansBaselineOnly() }),
        ("testNormalDeltaIsAccumulated", { TokenDeltaTests().testNormalDeltaIsAccumulated() }),
        ("testWideGapStillYieldsAnAmount", { TokenDeltaTests().testWideGapStillYieldsAnAmount() }),
        ("testCounterRegressionProducesNoDelta", { TokenDeltaTests().testCounterRegressionProducesNoDelta() }),
        ("testNoChangeProducesNoDelta", { TokenDeltaTests().testNoChangeProducesNoDelta() }),
    ]),

    ("HistoryGapTests", [
        ("testContinuousSamplesStayInOneSegment", { HistoryGapTests().testContinuousSamplesStayInOneSegment() }),
        ("testWideGapSplitsSegments", { HistoryGapTests().testWideGapSplitsSegments() }),
        ("testEmptyInputGivesNoSegments", { HistoryGapTests().testEmptyInputGivesNoSegments() }),
    ]),

    ("QuotaCycleTests", [
        ("testCounterDropStartsNewCycle", { QuotaCycleTests().testCounterDropStartsNewCycle() }),
        ("testMonotonicSamplesStayOneCycle", { QuotaCycleTests().testMonotonicSamplesStayOneCycle() }),
        ("testSplitIsPerQuotaKind", { QuotaCycleTests().testSplitIsPerQuotaKind() }),
    ]),

    ("KeyTests", [
        ("testAccountKeyIsStableAndDistinct", { KeyTests().testAccountKeyIsStableAndDistinct() }),
        ("testAccountKeyDoesNotContainRawId", { KeyTests().testAccountKeyDoesNotContainRawId() }),
        ("testDayKeyFormat", { KeyTests().testDayKeyFormat() }),
        ("testDayKeyRespectsTimeZone", { KeyTests().testDayKeyRespectsTimeZone() }),
    ]),

    ("AccountIdentityTests", [
        ("testSameFieldsAreTheSameAccount", { AccountIdentityTests().testSameFieldsAreTheSameAccount() }),
        ("testDifferentApiIdIsADifferentAccount", { AccountIdentityTests().testDifferentApiIdIsADifferentAccount() }),
        ("testDifferentBaseURLIsADifferentAccount", { AccountIdentityTests().testDifferentBaseURLIsADifferentAccount() }),
        ("testEmptyFieldsAreNotConfigured", { AccountIdentityTests().testEmptyFieldsAreNotConfigured() }),
        ("testStorageKeyIgnoresBaseURL", { AccountIdentityTests().testStorageKeyIgnoresBaseURL() }),
        ("testStorageKeyDistinguishesApiIds", { AccountIdentityTests().testStorageKeyDistinguishesApiIds() }),
        ("testStorageKeyDoesNotLeakTheRawApiId", { AccountIdentityTests().testStorageKeyDoesNotLeakTheRawApiId() }),
    ]),

    ("RefreshGateTests", [
        ("testIdleGateIsNotLoading", { RefreshGateTests().testIdleGateIsNotLoading() }),
        ("testBeginMarksTheAccountAsInFlight", { RefreshGateTests().testBeginMarksTheAccountAsInFlight() }),
        ("testSameAccountDoesNotReenter", { RefreshGateTests().testSameAccountDoesNotReenter() }),
        ("testDifferentAccountIsLetThroughWhileAnotherIsInFlight", { RefreshGateTests().testDifferentAccountIsLetThroughWhileAnotherIsInFlight() }),
        ("testStaleFinishDoesNotClearTheNewerInFlightMarker", { RefreshGateTests().testStaleFinishDoesNotClearTheNewerInFlightMarker() }),
        ("testFinishByTheInFlightAccountFreesTheGate", { RefreshGateTests().testFinishByTheInFlightAccountFreesTheGate() }),
        ("testUnconfiguredAccountIsRejected", { RefreshGateTests().testUnconfiguredAccountIsRejected() }),
        ("testSwitchingBackAllowsAFreshRefresh", { RefreshGateTests().testSwitchingBackAllowsAFreshRefresh() }),
    ]),

    ("HistoryStoreTests", [
        ("testInsertAndReadBack", { HistoryStoreTests().testInsertAndReadBack() }),
        ("testLastSampleIsTheNewest", { HistoryStoreTests().testLastSampleIsTheNewest() }),
        ("testEmptyStoreHasNoLastSample", { HistoryStoreTests().testEmptyStoreHasNoLastSample() }),
        ("testRangeQueryIsOrderedAndBounded", { HistoryStoreTests().testRangeQueryIsOrderedAndBounded() }),
        ("testTokenDeltaAccumulatesWithinADay", { HistoryStoreTests().testTokenDeltaAccumulatesWithinADay() }),
        ("testAccountsArePartitioned", { HistoryStoreTests().testAccountsArePartitioned() }),
        ("testPruneRemovesOldSamplesOnly", { HistoryStoreTests().testPruneRemovesOldSamplesOnly() }),
        ("testTransactionCommitsEverythingTogether", { HistoryStoreTests().testTransactionCommitsEverythingTogether() }),
        ("testTransactionRollsBackAPartialWrite", { HistoryStoreTests().testTransactionRollsBackAPartialWrite() }),
        ("testStoreStaysUsableAfterARollback", { HistoryStoreTests().testStoreStaysUsableAfterARollback() }),
        ("testNestedTransactionIsRejected", { HistoryStoreTests().testNestedTransactionIsRejected() }),
    ]),

    ("FieldValidityTests", [
        ("testNonNumericStringIsRejected", { FieldValidityTests().testNonNumericStringIsRejected() }),
        ("testWronglyTypedLimitsObjectIsRejected", { FieldValidityTests().testWronglyTypedLimitsObjectIsRejected() }),
        ("testWronglyTypedUsageObjectIsRejected", { FieldValidityTests().testWronglyTypedUsageObjectIsRejected() }),
        ("testNestedInvalidFieldKeepsItsOwnName", { FieldValidityTests().testNestedInvalidFieldKeepsItsOwnName() }),
        ("testUnwrapSurfacesTheOffendingFieldName", { FieldValidityTests().testUnwrapSurfacesTheOffendingFieldName() }),
        ("testCompleteResponseIsMarkedComplete", { FieldValidityTests().testCompleteResponseIsMarkedComplete() }),
        ("testMissingRequiredCostMakesUsageIncomplete", { FieldValidityTests().testMissingRequiredCostMakesUsageIncomplete() }),
        ("testNullRequiredCostMakesUsageIncomplete", { FieldValidityTests().testNullRequiredCostMakesUsageIncomplete() }),
        ("testMissingUsageTotalsMakeUsageIncomplete", { FieldValidityTests().testMissingUsageTotalsMakeUsageIncomplete() }),
        ("testMissingOptionalFieldsStayComplete", { FieldValidityTests().testMissingOptionalFieldsStayComplete() }),
        ("testRealResponseShapeStaysComplete", { FieldValidityTests().testRealResponseShapeStaysComplete() }),
    ]),

    ("IncompleteResponseTests", [
        ("testIncompleteSnapshotIsSkipped", { IncompleteResponseTests().testIncompleteSnapshotIsSkipped() }),
        ("testInvalidResponseLeavesNoZeroSample", { IncompleteResponseTests().testInvalidResponseLeavesNoZeroSample() }),
        ("testInvalidResponseDoesNotCauseATokenSpike", { IncompleteResponseTests().testInvalidResponseDoesNotCauseATokenSpike() }),
        ("testInvalidResponseNeverReachesResetLearning", { IncompleteResponseTests().testInvalidResponseNeverReachesResetLearning() }),
    ]),

    ("HistoryWriterTests", [
        ("testFirstWriteStoresTheSampleWithoutInventingUsage", { HistoryWriterTests().testFirstWriteStoresTheSampleWithoutInventingUsage() }),
        ("testFailureBetweenTheTwoWritesLeavesNoPartialCommit", { HistoryWriterTests().testFailureBetweenTheTwoWritesLeavesNoPartialCommit() }),
        ("testDeltaSurvivesAFailedRefreshAcrossRestart", { HistoryWriterTests().testDeltaSurvivesAFailedRefreshAcrossRestart() }),
        ("testResetDropsBaselinesSoANewAccountStartsClean", { HistoryWriterTests().testResetDropsBaselinesSoANewAccountStartsClean() }),
    ]),

    ("QuotaSeriesTests", [
        ("testRemainingRatioIsDerivedFromLimit", { QuotaSeriesTests().testRemainingRatioIsDerivedFromLimit() }),
        ("testUnlimitedQuotaProducesNoPoints", { QuotaSeriesTests().testUnlimitedQuotaProducesNoPoints() }),
        ("testContinuousSamplesShareOneSeries", { QuotaSeriesTests().testContinuousSamplesShareOneSeries() }),
        ("testGapStartsNewSeries", { QuotaSeriesTests().testGapStartsNewSeries() }),
        ("testResetStartsNewSeries", { QuotaSeriesTests().testResetStartsNewSeries() }),
        ("testOverspendClampsToZero", { QuotaSeriesTests().testOverspendClampsToZero() }),
        ("testEmptyInputProducesNoPoints", { QuotaSeriesTests().testEmptyInputProducesNoPoints() }),
        ("testGapIntervalsAreReported", { QuotaSeriesTests().testGapIntervalsAreReported() }),
        ("testNoGapsWhenContinuous", { QuotaSeriesTests().testNoGapsWhenContinuous() }),
        ("testGapProducesConnector", { QuotaSeriesTests().testGapProducesConnector() }),
        ("testResetConnectorStartsAtFullQuotaOnTheBoundary", { QuotaSeriesTests().testResetConnectorStartsAtFullQuotaOnTheBoundary() }),
        ("testResetProducesNoConnectorWithoutABoundary", { QuotaSeriesTests().testResetProducesNoConnectorWithoutABoundary() }),
        ("testOutOfRangeBoundaryIsRejected", { QuotaSeriesTests().testOutOfRangeBoundaryIsRejected() }),
        ("testContinuousSamplesNeedNoConnectors", { QuotaSeriesTests().testContinuousSamplesNeedNoConnectors() }),
        ("testGapConnectorEndpointsMatchTheSolidSegments", { QuotaSeriesTests().testGapConnectorEndpointsMatchTheSolidSegments() }),
        ("testResetTakesPrecedenceOverGap", { QuotaSeriesTests().testResetTakesPrecedenceOverGap() }),
    ]),

    ("LocalizationTests", [
        ("testEveryKeyIsTranslatedInEveryLanguage", { LocalizationTests().testEveryKeyIsTranslatedInEveryLanguage() }),
        ("testNoTranslationIsEmpty", { LocalizationTests().testNoTranslationIsEmpty() }),
        ("testPlaceholderCountsMatchAcrossLanguages", { LocalizationTests().testPlaceholderCountsMatchAcrossLanguages() }),
        ("testLookupReturnsRequestedLanguage", { LocalizationTests().testLookupReturnsRequestedLanguage() }),
        ("testFormatSubstitutesArguments", { LocalizationTests().testFormatSubstitutesArguments() }),
        ("testOnlyThreeLanguagesAreSupported", { LocalizationTests().testOnlyThreeLanguagesAreSupported() }),
        ("testSimplifiedAndTraditionalChineseAreDistinguished", { LocalizationTests().testSimplifiedAndTraditionalChineseAreDistinguished() }),
        ("testEnglishVariantsAreRecognised", { LocalizationTests().testEnglishVariantsAreRecognised() }),
        ("testUnsupportedLanguageFallsBackToEnglish", { LocalizationTests().testUnsupportedLanguageFallsBackToEnglish() }),
        ("testFirstRecognisedPreferenceWins", { LocalizationTests().testFirstRecognisedPreferenceWins() }),
        ("testEveryLanguageHasADisplayName", { LocalizationTests().testEveryLanguageHasADisplayName() }),
    ]),

    ("CycleStartTests", [
        ("testMomentInsideCurrentCycleReturnsItsStart", { CycleStartTests().testMomentInsideCurrentCycleReturnsItsStart() }),
        ("testExactBoundaryBelongsToTheCycleItStarts", { CycleStartTests().testExactBoundaryBelongsToTheCycleItStarts() }),
        ("testEarlierMomentStepsBackOneCycle", { CycleStartTests().testEarlierMomentStepsBackOneCycle() }),
        ("testMomentThreeCyclesEarlier", { CycleStartTests().testMomentThreeCyclesEarlier() }),
        ("testZeroDurationHasNoCycles", { CycleStartTests().testZeroDurationHasNoCycles() }),
    ]),

    ("TokenSeriesTests", [
        ("testParsesDayKeysIntoDates", { TokenSeriesTests().testParsesDayKeysIntoDates() }),
        ("testMissingDaysAreNotBackfilled", { TokenSeriesTests().testMissingDaysAreNotBackfilled() }),
        ("testMalformedDayKeyIsDropped", { TokenSeriesTests().testMalformedDayKeyIsDropped() }),
    ]),

    ("AlertPolicyTests", [
        ("testLowQuotaFires", { AlertPolicyTests().testLowQuotaFires() }),
        ("testComfortableQuotaDoesNotFire", { AlertPolicyTests().testComfortableQuotaDoesNotFire() }),
        ("testUnlimitedQuotaNeverFires", { AlertPolicyTests().testUnlimitedQuotaNeverFires() }),
        ("testOverPaceFiresAfterWindowHasProgressed", { AlertPolicyTests().testOverPaceFiresAfterWindowHasProgressed() }),
        ("testOverPaceIsSuppressedEarlyInWindow", { AlertPolicyTests().testOverPaceIsSuppressedEarlyInWindow() }),
        ("testOverPaceIsSuppressedWhenPlentyRemains", { AlertPolicyTests().testOverPaceIsSuppressedWhenPlentyRemains() }),
        ("testLowQuotaSupersedesOverPace", { AlertPolicyTests().testLowQuotaSupersedesOverPace() }),
        ("testAlertIsNotRepeatedWithinSameCycle", { AlertPolicyTests().testAlertIsNotRepeatedWithinSameCycle() }),
        ("testNewCycleAllowsAlertAgain", { AlertPolicyTests().testNewCycleAllowsAlertAgain() }),
        ("testWindowlessQuotaDedupesPerDay", { AlertPolicyTests().testWindowlessQuotaDedupesPerDay() }),
        ("testMultipleQuotasAlertIndependently", { AlertPolicyTests().testMultipleQuotasAlertIndependently() }),
    ]),
]
