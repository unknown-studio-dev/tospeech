# EchoLab Backend Review — Word Timing & các vấn đề khác

> Ngày review: 2026-09-11 · Phạm vi: `EchoLab/Services/Production/**` (persistence, import, practice/audio, preparation)
> Trọng tâm yêu cầu: **cắt timing audio theo từng từ** (word-level alignment) + đề xuất thư viện.

---

## TL;DR

- Luồng chính (caption YouTube) **không cắt được word timing tự động**, dù dữ liệu word timing **có sẵn miễn phí** trong file VTT tải về — code đang xóa nó bằng regex.
- Parser VTT tạo ra segment **bị lặp / rác** với auto-caption (cấu trúc rolling của YouTube).
- Dùng `SFSpeechRecognizer` **đã lỗi thời** trên macOS 26 (target của dự án), timestamp on-device thường = 0.
- Ngoài word-timing còn một số lỗi backend đáng chú ý: cancel không giết process con, yt-dlp chưa ký lại, thiếu `AVAudioSession`, rò rỉ prepared statement khi throw.

---

## Phần A — Word timing (trọng tâm)

### A1. 🔴 Word timing của YouTube bị xóa sạch (lỗi lớn nhất)

**Bằng chứng thực tế** — tải VTT auto-caption bằng chính yt-dlp bundled trong app:

```
00:00:08.960 --> 00:00:11.870 align:start position:0%
this program is brought to you by                                  ← dòng lặp của cue trước
Stanford<00:00:09.519><c> University</c><00:00:10.480><c> please</c><00:00:10.800><c> visit</c>...
                                                                    ← timestamp TỪNG TỪ có sẵn
```

Mỗi từ trong VTT có timestamp riêng dạng inline `<HH:MM:SS.mmm><c> word</c>`.

**Vấn đề trong code:**

| Vị trí | Vấn đề |
|---|---|
| `CaptionTranscript.swift:217` | `sanitize()` dùng regex `<[^>]+>` **xóa toàn bộ tag** → xóa luôn timestamp từng từ |
| `CaptionTranscript.swift:130-183` | `WebVTTCaptionParser.parse` chỉ đọc timing cấp câu → `CaptionCue.words = nil` **luôn luôn** |
| `CaptionTranscript.swift:272-278` | `tokens()`: khi `words == nil` → tách theo khoảng trắng, mỗi từ `startFrame: nil, needsTimingReview: true` |

**Hệ quả:** Với nguồn caption YouTube (≈99% lesson), **không có cắt timing tự động nào** — mọi từ phải chỉnh tay.

### A2. 🔴 Parser VTT tạo câu lặp/rác với auto-caption

Auto-caption YouTube có cấu trúc "rolling": mỗi cue lặp lại câu trước ở dòng 1 + thêm từ mới ở dòng 2, xen kẽ các cue "nhấp nháy" dài ~10ms.

- `CaptionTranscript.swift:169-177` join tất cả dòng bằng `" "` và **không khử trùng lặp**, không gộp cue nhấp nháy → segment lặp text, chồng nhau.
- `CaptionTranscriptBuilder.build` `:234-236` kẹp cue vượt cuối audio thành segment 1-frame vô dụng.

### A3. 🟠 Word timing của Apple Speech được tính rồi vứt

- `ProductionImportService.swift:378` — `CaptionAudioMismatchDetector.markingReview` chỉ set `timingReviewReason`, vẫn truyền `words: caption.words` (= nil). Timing ASR **không dùng để điền frame**.
- Đây là thiết kế bảo thủ cố ý (`CaptionTranscript.swift:291-293`), nhưng cái giá là mất toàn bộ word timing.

### A4. 🟠 `SFSpeechRecognizer` lỗi thời trên macOS 26

- `AppleSpeechCaptionTranscriber.swift` dùng `SFSpeechRecognizer` + `SFSpeechURLRecognitionRequest`.
- On-device macOS: `segment.timestamp`/`duration` thường = 0 → drop hết từ (`:92-98`) → ném `.noTranscription` dù transcript ổn.
- `SFSpeechURLRecognitionRequest` có trần ~1 phút → lesson dài mất phần sau.
- Không timeout, không cancellation, continuation có thể resume 2 lần (crash tiềm ẩn) — `:68-81`.

---

## Phần B — Kiến trúc đã chốt: "audio-first"

> **Insight quyết định:** timing YouTube không đáng tin → **bỏ hẳn timing YouTube**. Cả ranh giới câu lẫn word timing đều suy từ audio nói. YouTube caption chỉ còn dùng để lấy **text sạch**.

### Quyết định đã chốt

| Điểm | Chốt |
|---|---|
| **Engine timing chính** | **WhisperKit** (`argmaxinc/whisperkit`, Swift SPM, on-device Core ML) — chính xác nhất, có VAD built-in + dấu câu tốt, chunk audio dài tự động. |
| **Nguồn text** | Ưu tiên **text YouTube caption** (sạch chính tả/tên riêng) ghép vào **timing WhisperKit** bằng forced alignment. Không có caption → thuần ASR. |
| **Offline / model** | Cho **tải model 1 lần** (UI tiến trình). Lỗi tải → **retry**. **Chỉ cho chạy preparation khi model đã cài + verify xong.** |

### B1. Cắt câu tự nhiên theo audio (thuật toán)

Ba tín hiệu kết hợp: **dấu câu (ngữ nghĩa) + khoảng lặng (nhịp nói) + VAD (snap vào silence)**.

```
1. WhisperKit → words[] = {text, startFrame, endFrame} + dấu câu (. , ? !)
2. gap[i] = words[i+1].start − words[i].end            (khoảng lặng giữa 2 từ)
3. Ranh giới câu = nơi:
     • từ kết thúc bằng . ? !                            (dấu câu)   HOẶC
     • gap[i] > ngưỡng nghỉ (mặc định ~0.6s)             (người nói dừng thở)
4. Gộp/tách cho tự nhiên:
     • câu quá dài, không dấu câu → tách tại gap lớn nhất
     • câu quá ngắn (< ~1.2s)     → gộp với câu kế
     • giới hạn max (vd ~12s)
5. Snap ranh giới ra khoảng lặng gần nhất (VAD) → không cắt cụt từ
6. startFrame/endFrame lấy từ word timestamps, đệm nhẹ vào vùng lặng
```

→ Ranh giới rơi vào **khoảng lặng thật** trong audio → nghe tự nhiên, word timing khớp thật.

### B2. Ghép text YouTube vào timing ASR (forced alignment / reconciliation)

Text ASR ≠ text caption (số từ khác) → không copy thẳng:
- Căn 2 chuỗi token chuẩn hóa bằng **Needleman-Wunsch / DTW**, gán mỗi từ caption → khoảng thời gian ASR gần nhất.
- Codebase **đã có LCS** ở `CaptionAudioMismatchDetector.swift:336` — mở rộng thành alignment đầy đủ.
- Xuất frame + **độ tin cậy từng từ**; `needsTimingReview` bật theo confidence (không bật mù).
- Từ caption không khớp được từ ASR nào → giữ text nhưng cờ review.

### B3. Cổng cài model (dùng bảng `engine_installations` đã có sẵn)

Schema đã có `engine_releases` + `engine_installations` (status: `not_installed → downloading → verifying → installed / failed / removing`) — map thẳng vào vòng đời model WhisperKit:

```
Chưa cài  → Settings hiện nút "Tải model nhận dạng"
Tải       → status=downloading (UI %)  ; lỗi → status=failed → nút Retry
Xong      → status=verifying (checksum) ; lỗi → failed → Retry
Verify OK → status=installed
Preparation CHỈ chạy khi status=installed. Nếu chưa → chặn + hướng dẫn cài.
```

> `EchoLab.entitlements` đã có `network.client` → tải model hợp lệ. Model là **asset**, không phải inference cloud → không vi phạm nguyên tắc "no cloud request" của ARCHITECTURE. Bundle sẵn model = app nặng thêm vài trăm MB nên chọn hướng tải-1-lần.

### B4. Vai trò YouTube caption sau khi đổi

- ❌ **Bỏ hoàn toàn timing YouTube** (không parse inline tag, không tin `-->` cho word cut).
- ✅ Vẫn tải caption để lấy **text** → alignment (B2).
- Không caption → thuần ASR, vẫn tự động 100%.
- Mô hình dữ liệu đã lường trước: `TranscriptSource.appleSpeech` (đổi tên/thêm `.whisper`), `CaptionBaseline`, `SegmentTimingRevisionDraft` giữ nguyên.

### B5. Thư viện tham chiếu (đã cân nhắc, không chọn)

| Thư viện | Vì sao không chọn |
|---|---|
| Apple SpeechTranscriber (macOS 26) | Native, nhẹ hạ tầng, nhưng độ chính xác text < Whisper large; giữ làm **fallback** khả dĩ. |
| whisper.cpp | Tương đương WhisperKit nhưng nhiều việc tay hơn; WhisperKit đã bọc Core ML sẵn. |
| wav2vec2 / MMS-FA (CTC forced alignment) | Chất lượng align cao nhất nhưng phải tự port Core ML — để dành nếu DTW của Whisper chưa đủ. |
| MFA / WhisperX / aeneas | **Python**, không nhúng được vào Mac app sandbox. |

### Kế hoạch triển khai (thứ tự)

1. **Tích hợp WhisperKit** (SPM) + cổng cài model qua `engine_installations` (B3).
2. **`WhisperCaptionTranscriber`** — thay `AppleSpeechCaptionTranscriber` làm nguồn word timing chính (word timestamp + dấu câu + VAD).
3. **`NaturalSentenceSegmenter`** — thuật toán B1 (thuần logic, dễ unit-test).
4. **`TranscriptAligner`** — forced alignment B2 (mở rộng LCS sẵn có).
5. **Sửa import**: `ProductionImportService` gọi ASR-first; caption YouTube chỉ để lấy text.
6. Xử lý các lỗi Apple Speech ở Phần C nếu vẫn giữ SpeechTranscriber làm fallback.

---

## Phần C — Các lỗi backend khác

### Import / subprocess (`Services/Production/Import/`)

| Mức | Vị trí | Vấn đề |
|---|---|---|
| 🔴 | `SubprocessRunner.swift:115` | Cancel chỉ SIGTERM/SIGKILL pid trực tiếp; ffmpeg/qjs con của yt-dlp sống sót → ngốn CPU, ghi file rác. Cần `kill(-pgid)` cho cả process group. |
| 🔴 | `scripts/stage-toolchain.sh:19` | `yt-dlp_macos` **không được ký lại** (chỉ ký ffmpeg/ffprobe/qjs). Hardened runtime + sandbox, không có `disable-library-validation` → fail trên máy người dùng thật. |
| 🟠 | `SubprocessRunner.swift:73-79` | Data race đọc `FileHandle` từ `readabilityHandler` + `terminationHandler` cùng lúc → crash ObjC exception tiềm ẩn. |
| 🟠 | `ProductionImportService.swift:623` | `sha256` (`Data(contentsOf:)`) hash file nặng **trên actor** → block Cancel + refresh UI khi publish. Nên stream-hash off-actor + cache toolchain. |
| 🟠 | `ProductionImportService.swift:316-327` | File local security-scoped truyền path cho ffmpeg con → sandbox có thể chặn (con không kế thừa quyền). Nên copy vào workspace trước. |
| 🟡 | `ProductionImportService.swift:307` | Thiếu thumbnail làm **fail cả import** dù thumbnail vốn optional. Workspace lỗi không dọn → cache phình. |
| 🟡 | `ProductionImportService.swift:299,326,522` | Chưa có `--` trước URL/path do user cấp (argument injection nếu value bắt đầu bằng `-`). |

### Audio / practice (`Services/Production/Practice/`)

| Mức | Vị trí | Vấn đề |
|---|---|---|
| 🔴 | toàn bộ subsystem | **Không có `AVAudioSession`** ở đâu → iOS record/playback hỏng; interruption (cuộc gọi) + đổi route (rút tai nghe) không xử lý → CAF dở dang, state kẹt `.recording`. |
| 🟠 | `ProductionPracticeService.swift:220` | `finishCapture` khi `recorder.finish()` throw → kẹt trạng thái không retry được. |
| 🟠 | `ProductionPracticeService.swift:263` | Launch recovery dừng ở manifest hỏng đầu tiên → mất hết take tốt còn lại. File `.caf` mồ côi sau crash không dọn. |
| 🟠 | `ProductionAudioPlayer.swift:53` | Không kiểm `sampleRate` file khớp `target.sampleRate` từ DB → cắt sai đoạn, seek desync. |
| 🟡 | `ProductionAudioPlayer.swift:65`, `ProductionPracticeController.swift:249` | Pause/aux playback không `engine.stop()` → rò tài nguyên khi rời màn hình lúc pause. |

### Preparation (`Services/Production/Preparation/`)

| Mức | Vị trí | Vấn đề |
|---|---|---|
| 🟠 | `AppleSpeechCaptionTranscriber.swift:51-54` | Audio > ~60s: `SFSpeechURLRecognitionRequest` truncate/fail. Cần chia cửa sổ < 60s theo silence rồi merge. |
| 🟠 | `AppleSpeechCaptionTranscriber.swift:92-119` | Segment timestamp=0 → drop hết → `.noTranscription` sai dù có text. |
| 🟠 | `AppleSpeechCaptionTranscriber.swift:68-81` | Không timeout/cancellation → treo vĩnh viễn; continuation có thể resume 2 lần → crash. |
| 🟡 | `AppleTranslationPreparer.swift:55-67` | Lỗi dịch một phần bị nuốt lặng → câu thiếu bản dịch mà pipeline báo thành công. |
| 🟡 | `CaptionTranscript.swift:136` | Header check fail nếu VTT có BOM (`﻿`). |
| 🟡 | `OfflineIPADictionary.swift:90` | Chuẩn hóa lookup key giữ dấu/underscore → có thể miss từ điển. Cần khớp normalization của build script. |

### Persistence (`Services/Production/Persistence/ProductionDatabase.swift`)

| Mức | Vị trí | Vấn đề |
|---|---|---|
| 🟠 | `:407,485,506,639` (publishImportedAssets / publishPreparedLesson / publishTimingRevision / completeLessonDeletion) | Prepared statement finalize thủ công ở cuối thay vì `defer`. Nếu `stepDone` throw giữa chừng → rò handle trong transaction. Nên bọc `defer { sqlite3_finalize(...) }`. |
| 🟡 | `:276` | SQL nội suy chuỗi (`job_id = '\(id.uuidString)'`) — an toàn vì UUID nhưng lệch chuẩn parameterized. Nên bind `?`. |

---

## Spike #3 findings — WhisperKit feasibility (2026-09-11)

Kết quả spike tích hợp WhisperKit (đầu vào cho Plan #3 chi tiết):

- **Version:** pin `exactVersion: 1.1.0` (bản ổn định mới nhất, 2026-08-06). Repo `argmaxinc/WhisperKit` nay là mono-package `argmax-oss-swift` (product: `WhisperKit`, `TTSKit`, `SpeakerKit`, CLI).
- **✅ Dependency tree sạch:** Xcode resolve chỉ `argmax-oss-swift` + `swift-argument-parser`. Vapor/OpenAPI bị gate sau `isServerEnabled()`/`BUILD_ALL` → **không resolve**. Không có `swift-transformers` (đã vendored vào `ArgmaxCore`).
- **✅ Chỉ build WhisperKit, không dính TTSKit:** target `WhisperKit` chỉ phụ thuộc `ArgmaxCore`. `TTSKit` (product khác) có lỗi build `Qwen3SpeechDecoder.swift` non-Sendable dưới toolchain này — **vô can** vì app chỉ dùng `product: WhisperKit`. (Chỉ `swift build` CLI mới build cả package.)
- **✅ Compile trong project dưới `SWIFT_STRICT_CONCURRENCY: complete`:** đã thêm vào `project.yml` (`packages:` + `dependencies: package: WhisperKit`), build app + **102 test vẫn pass**.
- **⚠️ `WhisperKit` là `open class` KHÔNG Sendable** → phải bọc trong **actor riêng** (đã dựng `WhisperKitProbe.swift`). Kết quả `TranscriptionResult`/`TranscriptionSegment`/`WordTiming` đều `Sendable` → map ra `[TimedWord]` qua actor boundary OK.
- **✅ Model redirect sandbox-safe:** `WhisperKitConfig(model:downloadBase:...)` — `downloadBase: URL?` cho phép đổ model vào thư mục tự chọn (proof: model `tiny.en` ~124MB tải đúng vào dir chỉ định). Plan #3 dùng `BackendPaths.packages`, **không** ghi vào `~/Documents/huggingface`.
- **API bọc:** `init(_ config: WhisperKitConfig) async throws`; `transcribe(audioPath: String, decodeOptions: DecodingOptions? = nil) async throws -> [TranscriptionResult]`; bật `DecodingOptions(wordTimestamps: true)`; `WordTiming { word, start: Float, end: Float, probability: Float }`.
- **Bonus:** package có sẵn `EnergyVAD` / `VoiceActivityDetector` (`voiceActivityDetector:` trong config) — dùng cho VAD snapping ở Plan #4.

- **✅ Runtime word-timestamps thật** (exe standalone chỉ-WhisperKit, model `tiny.en`, câu test `"Hello world. How are you today? I am doing very well."`):

  ```
    0.000  0.420  p=0.87  |Hello|
    0.420  0.960  p=0.63  |world,|
    1.400  1.560  p=0.95  |how|      ← gap 0.44s sau "world," = ranh giới câu
    ...    ...            |today?|   ← gap 0.54s sau "today?" = ranh giới câu
    2.800  2.960  p=0.82  |I'm|      ← "I am" → whisper nghe "I'm" ⇒ cần aligner (Plan #2)
    3.580  3.920  p=1.00  |well.|
  ```
  Dấu câu **dính vào từ** ("world,", "today?", "well.") đúng thứ `NaturalSentenceSegmenter.sentenceEnds` cần; khoảng lặng giữa câu hiện rõ; timing đơn điệu tăng; có `probability` từng từ → điều khiển `needsTimingReview`.

**Pass/fail:** ✅ dep tree · ✅ compile in-project + 102 test xanh · ✅ model redirect sandbox-safe · ✅ runtime word-timestamps + dấu câu. **Tất cả tiêu chí Go đạt.**

**Đã chốt model (cho Plan #3):**
- **Default = `small.en`** (~480MB, chính xác tốt cả giọng US lẫn UK, tốc độ vừa).
- **User chọn 4 mức** trong Settings: `tiny.en` (~75MB) · `base.en` (~145MB) · `small.en` (~480MB, default) · `large-v3` (~1.5GB, chính xác nhất). Cắm vào UI `ModelPackage`/`PackageStatus` sẵn có (`Features/Settings/RecordingModelsSettingsView`).
- Tải-1-lần qua `engine_installations` (có retry, chỉ chạy khi `installed`).
- **Import KHÔNG hỏi chọn model.** User chọn/tải model **chỉ ở Settings** (1 model active tại một thời điểm). Import/preparation dùng model đang active. Nếu chưa có model `installed` → chặn import + hướng dẫn vào Settings tải (cổng cài model).

**Làm rõ US/UK (quan trọng — tránh over-engineer):**
- Model Whisper **KHÔNG theo giọng**: một model `.en` transcribe chuẩn cả người nói US lẫn UK. "US/UK" ở đây KHÔNG phải chọn model — chỉ chọn *kích thước* (chính xác ↔ tốc độ). Model lớn = khỏe hơn với giọng khó.
- **IPA phát âm tham chiếu US/UK** cho learner là hệ thống **đã có sẵn, tách biệt**: `ReferenceAccent` + `OfflineIPADictionary` (britfone=UK, ipa-dict=US). Word-timing pipeline không đụng tới. → App đã hỗ trợ US+UK ở tầng phát âm.

## Nguồn tham khảo

- [SpeechAnalyzer — WWDC25](https://developer.apple.com/videos/play/wwdc2025/277/)
- [WhisperKit (argmax)](https://github.com/argmaxinc/whisperkit)
- [WhisperX — word-level forced alignment](https://github.com/m-bain/whisperx)
- [yt-dlp subtitle formats guide (2026)](https://skipthewatch.com/blog/yt-dlp-youtube-subtitles)

---

## Đề xuất bước tiếp theo

Theo kiến trúc audio-first đã chốt (Phần B). Bắt đầu từ **B3 → B1 → B2**:

1. Tích hợp **WhisperKit** + cổng cài model qua `engine_installations` (B3) — có retry, chặn chạy tới khi `installed`.
2. `WhisperCaptionTranscriber` + `NaturalSentenceSegmenter` (B1) — cắt câu tự nhiên theo khoảng lặng.
3. `TranscriptAligner` (B2) — ghép text YouTube vào timing ASR.
4. Sửa `ProductionImportService` sang ASR-first; caption YouTube chỉ lấy text.

> Ghi chú: **Tier 0 (parse timing VTT) đã bị loại** vì timing YouTube không đáng tin — chỉ giữ caption để lấy text.
