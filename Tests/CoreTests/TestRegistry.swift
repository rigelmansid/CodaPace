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
        ("testFixedSelectionIsHonoured", { MenuBarSourceTests().testFixedSelectionIsHonoured() }),
        ("testFixedSelectionFallsBackWhenUnlimited", { MenuBarSourceTests().testFixedSelectionFallsBackWhenUnlimited() }),
    ]),

    ("SnapshotBuilderTests", [
        ("testBuildsFourGaugesInDisplayOrder", { SnapshotBuilderTests().testBuildsFourGaugesInDisplayOrder() }),
        ("testTotalGaugeNeverGetsAWindow", { SnapshotBuilderTests().testTotalGaugeNeverGetsAWindow() }),
        ("testEmptyNameFallsBackToPlaceholder", { SnapshotBuilderTests().testEmptyNameFallsBackToPlaceholder() }),
    ]),

    ("SamplingPolicyTests", [
        ("testFirstSampleIsAlwaysRecorded", { SamplingPolicyTests().testFirstSampleIsAlwaysRecorded() }),
        ("testChangedValuesAreRecorded", { SamplingPolicyTests().testChangedValuesAreRecorded() }),
        ("testUnchangedWithinAnchorIntervalIsSkipped", { SamplingPolicyTests().testUnchangedWithinAnchorIntervalIsSkipped() }),
        ("testUnchangedPastAnchorIntervalIsRecorded", { SamplingPolicyTests().testUnchangedPastAnchorIntervalIsRecorded() }),
    ]),

    ("TokenDeltaTests", [
        ("testNoPreviousMeansBaselineOnly", { TokenDeltaTests().testNoPreviousMeansBaselineOnly() }),
        ("testNormalDeltaIsAccumulated", { TokenDeltaTests().testNormalDeltaIsAccumulated() }),
        ("testWideGapIsNotAttributedToToday", { TokenDeltaTests().testWideGapIsNotAttributedToToday() }),
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

    ("HistoryStoreTests", [
        ("testInsertAndReadBack", { HistoryStoreTests().testInsertAndReadBack() }),
        ("testLastSampleIsTheNewest", { HistoryStoreTests().testLastSampleIsTheNewest() }),
        ("testEmptyStoreHasNoLastSample", { HistoryStoreTests().testEmptyStoreHasNoLastSample() }),
        ("testRangeQueryIsOrderedAndBounded", { HistoryStoreTests().testRangeQueryIsOrderedAndBounded() }),
        ("testTokenDeltaAccumulatesWithinADay", { HistoryStoreTests().testTokenDeltaAccumulatesWithinADay() }),
        ("testAccountsArePartitioned", { HistoryStoreTests().testAccountsArePartitioned() }),
        ("testPruneRemovesOldSamplesOnly", { HistoryStoreTests().testPruneRemovesOldSamplesOnly() }),
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
        ("testZeroDurationWindowHasNoCycles", { CycleStartTests().testZeroDurationWindowHasNoCycles() }),
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
