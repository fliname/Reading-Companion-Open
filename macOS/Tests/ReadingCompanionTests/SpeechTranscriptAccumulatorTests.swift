import Foundation
import Testing
@testable import ReadingCompanion

@Suite("Speech transcript accumulation")
struct SpeechTranscriptAccumulatorTests {
    @Test func recognizesTaskAndURLSessionCancellationWithoutShowingAnError() {
        #expect(ReaderModel.isCancellationError(CancellationError()))
        #expect(ReaderModel.isCancellationError(URLError(.cancelled)))
        #expect(!ReaderModel.isCancellationError(URLError(.timedOut)))
    }

    @Test func keepsFinalizedSpeechWhenNextPhraseBegins() {
        var accumulator = SpeechTranscriptAccumulator()

        #expect(accumulator.receive("第一段内容", isFinal: false) == "第一段内容")
        #expect(accumulator.receive("第一段内容。", isFinal: true) == "第一段内容。")
        #expect(accumulator.receive("停顿后的第二段", isFinal: false) == "第一段内容。停顿后的第二段")
        #expect(accumulator.receive("停顿后的第二段。", isFinal: true) == "第一段内容。停顿后的第二段。")
    }

    @Test func replacesOnlyTheCurrentPartialResult() {
        var accumulator = SpeechTranscriptAccumulator()
        _ = accumulator.receive("已经确认。", isFinal: true)
        _ = accumulator.receive("正在说", isFinal: false)

        #expect(accumulator.receive("正在说的新内容", isFinal: false) == "已经确认。正在说的新内容")
        #expect(accumulator.committed == "已经确认。")
    }

    @Test func avoidsRepeatingOverlappingRecognitionText() {
        var accumulator = SpeechTranscriptAccumulator()
        _ = accumulator.receive("这是已经识别的内容", isFinal: true)

        #expect(accumulator.receive("识别的内容和下一句", isFinal: true) == "这是已经识别的内容和下一句")
    }

    @Test func insertsSpacesBetweenEnglishPhrasesOnly() {
        #expect(SpeechTranscriptAccumulator.merge("keep", "speaking") == "keep speaking")
        #expect(SpeechTranscriptAccumulator.merge("继续", "输入") == "继续输入")
    }
}
