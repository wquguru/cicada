<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Biểu tượng Cicada">
</p>

<h1 align="center">Cicada · 知了</h1>

<p align="center">
  Mọi cuộc gọi. Mọi luồng phát. Không rào cản ngôn ngữ.<br>
  Hiểu, đáp lại, và ghi nhớ mọi thứ. Biên bản cuộc họp trực tiếp, bản chép lời song ngữ, phụ đề và phiên dịch trên Mac, Windows, Linux và Android.
</p>

<p align="center">
  <a href="https://cicada.indaloop.app/vi/"><img src="https://img.shields.io/badge/Website-cicada.indaloop.app-E8552B?style=for-the-badge" alt="Website: cicada.indaloop.app" height="36"></a>
  &nbsp;
  <a href="https://cicada.indaloop.app/vi/download/"><img src="https://img.shields.io/badge/Download-Mac%20·%20Windows%20·%20Linux%20·%20Android-15171C?style=for-the-badge" alt="Tải cho Mac, Windows, Linux và Android" height="36"></a>
  &nbsp;
  <a href="https://x.com/wquguru"><img src="https://img.shields.io/badge/Follow-@wquguru-000000?style=for-the-badge&logo=x&logoColor=white" alt="Theo dõi @wquguru trên X" height="36"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.4%2B-black" alt="macOS 14.4+">
  <img src="https://img.shields.io/badge/Windows-10%202004%2B-black" alt="Windows 10 2004+">
  <img src="https://img.shields.io/badge/Ubuntu-22.04%2B-black" alt="Ubuntu 22.04+">
  <img src="https://img.shields.io/badge/Android-10%2B-black" alt="Android 10+">
  <img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="Apache-2.0">
</p>

<p align="center">⭐ Hãy gắn sao repo này nếu bạn thấy nó hữu ích, để sau này tìm lại được</p>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.vi.md">Tiếng Việt</a></p>

> [!WARNING]
> **Lưu ý**: Cicada không liên quan gì tới bất kỳ loại tiền mã hóa, token hay NFT nào. Chúng tôi chưa bao giờ phát hành coin và sẽ không bao giờ làm vậy.

Trong các cuộc họp hay livestream, Cicada cho bạn phụ đề song ngữ trực tiếp và viết biên bản cuộc họp có cấu trúc trong lúc nghe. Khi tới lượt bạn nói, hãy giữ phím nói (⌥ phải trên Mac, Ctrl phải trên Windows, tùy chỉnh được) và nói — phía bên kia nghe giọng bạn đã dịch ngay trong cuộc gọi. Cicada nghe âm thanh hệ thống trực tiếp mà không gửi bot vào cuộc họp, nên không ai khác nhận ra điều gì. Trên máy Mac Apple silicon, toàn bộ nhận dạng giọng nói chạy trên thiết bị, nên âm thanh không bao giờ rời khỏi máy tính của bạn.

**Dùng được ở đâu**: Bất cứ thứ gì phát âm thanh trên máy tính của bạn — Tencent Meeting, Feishu, DingTalk, WeCom, Zoom, Teams, Google Meet, Webex, Discord và các cuộc trò chuyện thoại trên Telegram, cộng X Spaces, YouTube, Twitch, Bilibili Live, podcast và trang web. Trên điện thoại, hệ thống chặn ghi âm từ ứng dụng gọi điện và họp — hãy mở loa ngoài và dùng Mặt đối mặt thay thế.

<p align="center">
  <img src="docs/demo.gif" width="800" alt="Một buổi livestream tiếng Anh của Bloomberg trên YouTube với biên bản trực tiếp, chủ đề và sơ đồ xương cá của Cicada ở bên phải và phụ đề song ngữ ở phía dưới">
</p>

## Nền tảng

| Nền tảng | Yêu cầu | Ghi chú |
|---|---|---|
| Mac | macOS 14.4+, Apple silicon / Intel | Đầy đủ tính năng. Nhận dạng trên thiết bị trên Apple silicon (dùng được không cần key); Intel cần Ling key (giọng nói do Ming nhận dạng) |
| Windows | Windows 10 2004+, x64 / ARM64 | Cần key dịch vụ AI (Ling, OpenRouter, ZenMux, v.v.); xem [windows/](windows/README.md) |
| Linux | Ubuntu 22.04 / 24.04 desktop | Cần key dịch vụ AI; cửa sổ biên bản hiện trong chia sẻ màn hình; xem [linux/](linux/README.md) |
| Android | Android 10+ | Cần key dịch vụ AI; phụ đề cho video và luồng phát, phiên dịch mặt đối mặt; xem [android/](android/README.md) |

Gói cài đặt có trên [trang tải xuống](https://cicada.indaloop.app/vi/download/) và [Releases](https://github.com/wquguru/cicada/releases). Cả bốn nền tảng dùng chung số phiên bản và định dạng bản ghi cuộc họp. Các mục dưới đây dùng ứng dụng Mac để đi qua các tính năng.

## Tính năng

### Biên bản trực tiếp và bản chép lời song ngữ

Trong lúc bạn nghe, Cicada sắp xếp tóm tắt, chủ đề và điểm chính, kết luận, việc cần làm, sơ đồ xương cá, và bảng thuật ngữ tên và thuật ngữ. Nhấn vào bất kỳ kết luận hay việc cần làm nào để nhảy thẳng về các dòng gốc. Nhấn `⌘F` để tìm kiếm — cả từ đồng âm bị nhận nhầm cũng hiện ra.

Khi có dịch vụ AI kết nối, tên và thuật ngữ nghe nhầm được sửa tại chỗ: từ đồng âm được sửa ngay, còn tên lạ được hỏi một lần và tự sửa sau khi bạn xác nhận. Bạn có thể dán các thuật ngữ thường dùng vào **Danh sách từ** trong Cài đặt từ trước. Sau cuộc họp, chọn **Sửa dòng…** để sửa hàng loạt cùng một từ nghe nhầm trong toàn bộ buổi, với hỗ trợ hoàn tác đầy đủ.

### Phụ đề trực tiếp và phát hiện ngôn ngữ

Cicada phát hiện ngôn ngữ được nói trong vài giây và dịch nó sang ngôn ngữ hệ thống của bạn; nhấn `⌃⌥S` để chuyển chế độ hiển thị. Thanh phụ đề chỉ xuất hiện khi có người nói và trở nên trong suốt dưới con trỏ của bạn để không chắn đường. Trên macOS 26 với Apple silicon, Cicada cũng nghe lại trên thiết bị để hiệu chỉnh mỗi dòng sau 15 tới 30 giây, sửa lỗi chính tả và từ bị sót.

### Cuộc họp trực tiếp và kết hợp

Nhấn **Bật micrô** để thu người nói trong phòng. Cuộc họp kết hợp dùng cùng nút này: âm thanh máy tính được đánh dấu **Trực tuyến** và âm thanh micrô được đánh dấu **Trong phòng**, gộp trong một bản ghi duy nhất (trên macOS 14 và 15, bật micrô chỉ nghe phòng). Khi mở loa ngoài, Cicada tự khử trùng lặp âm thanh; khi đeo tai nghe, cả hai phía nói cùng lúc được và cả hai đều được giữ. Windows và Linux theo cùng quy tắc.

Trên Mac, mũi tên nhỏ bên cạnh nút chọn micrô nào sẽ dùng (chẳng hạn iPhone hoặc micrô phòng họp) mà không đổi mặc định của hệ thống. Những gì micrô nghe được chỉ vào biên bản, không bao giờ vào cuộc họp; để phía bên kia nghe được bạn, hãy dùng phiên dịch đồng thời dưới đây.

### Phiên dịch đồng thời

Giữ phím ⌥ phải và nói để phía bên kia nghe giọng bạn đã dịch trong ứng dụng họp.

Trên Mac, bạn cũng có thể bật **Rảnh tay** trong **Cài đặt › Phiên dịch**: cứ bắt đầu nói trong lúc nghe cuộc họp, âm thanh cuộc họp tự nhỏ xuống, và giọng bạn đã dịch đi ra sau 1 giây tạm dừng. Nó tạm dừng trong lúc micrô đang bật, và chúng tôi khuyên chuyển lại sang phím nói khi có người khác ở gần để giọng của họ không bị nhầm là của bạn.

Bật phiên dịch sẽ chuyển micrô hệ thống sang BlackHole 2ch, một driver ảo bạn tải và cài được bằng một nhấn. Với Ling API key, bạn dùng được giọng tự nhiên hoặc nhân bản giọng của chính mình từ một bản ghi 8 tới 30 giây; không có key, bạn vẫn dùng được giọng tích hợp của macOS. Phiên dịch trên Windows và Linux, và Mặt đối mặt của Android, cũng dùng được giọng của chính bạn, nhân bản từ bản ghi 10 tới 15 giây với Ling key.

<p align="center">
  <img src="docs/interpreting.png" width="640" alt="Cài đặt phiên dịch cho thấy phím nói Option phải, ngôn ngữ đích, bản nghe thử giọng Ming, và giọng macOS">
</p>

### Bản ghi cuộc họp

Bản chép lời song ngữ, biên bản, và bản ghi âm gốc được lưu trên thiết bị của bạn. Nhấn vào bất kỳ dòng nào để phát từ điểm đó trong lúc văn bản tô sáng và cuộn theo. Mô hình vân tay giọng nói trên thiết bị tự phân tách người nói (và điền tên của họ khi có Ling key), và bạn đổi tên hoặc gộp họ bất cứ lúc nào nếu ai đó bị nhận nhầm. Trên Mac, đặt tên cho một người nói và nhấn **Ghi nhớ giọng này** (hãy hỏi họ trước) và các cuộc họp sau nhận ra họ; vân tay giọng nói ở lại trên máy Mac này, và **Cài đặt › Chung › Ghi nhớ người nói** quản lý hoặc xóa nó. Hiện tại "bạn" trong bản ghi chỉ bao gồm những gì bạn nói trong lúc giữ phím nói; việc thu những gì bạn nói trực tiếp trong cuộc họp nằm trong [lộ trình](#lộ-trình).

Sau cuộc họp, bạn tạo biên bản bù được, nhấn vào tóm tắt, một kết luận hoặc việc cần làm trong cửa sổ chính để sửa tại chỗ, dùng **Chép lời lại** trên bản ghi âm nếu ngôn ngữ bị chọn sai, xuất sang Markdown, Word, và phụ đề SRT, hoặc chép lời các tệp âm thanh và video cục bộ qua **Tệp › Nhập bản ghi âm hoặc video…**. Trên Mac, **Sao chép biên bản** (⇧⌘C) dán vào Feishu, Notion hoặc Word với tiêu đề, danh sách và hình xương cá của nó, và dán dạng Markdown vào cuộc trò chuyện. Bật **Cài đặt › Chung › Lưu vào thư mục** và mỗi cuộc họp cũng tự được lưu dạng Markdown (với frontmatter ở đầu cho các agent) vào kho Obsidian hoặc thư mục khác, tự cập nhật mỗi khi bạn đổi tên nó hoặc tạo lại biên bản.

Nhấn **Chia sẻ…** để tạo liên kết tới biên bản (tùy chọn kèm toàn văn song ngữ) với thời hạn và mật khẩu; trước khi tải lên, nó tự chặn khóa, thông tin công ty chưa công bố, và nội dung nhạy cảm khác.

<p align="center">
  <img src="docs/records.png" width="640" alt="Cửa sổ bản ghi cuộc họp cho thấy người nói đã nhận diện và bản chép lời tiếng Anh và tiếng Trung theo từng dòng">
</p>

## Quyền riêng tư & Quyền truy cập

**Máy Mac Apple silicon**: Ghi âm và nhận dạng giọng nói chạy trên máy tính của bạn; âm thanh không bao giờ rời khỏi nó. Chỉ văn bản đã nhận dạng được gửi ra (để dịch và làm biên bản cuộc họp). Ngoại lệ: các câu bạn nói trong lúc phiên dịch khi đã cấu hình Ling key, nhấn **Tạm dùng Ling**, hoặc chuyển sang dịch vụ tự lưu trữ trong **Cài đặt › Dịch vụ AI** sẽ gửi âm thanh tới dịch vụ tương ứng. Không có API key, phụ đề trực tiếp, dịch, bản ghi cuộc họp, và phiên dịch đều dùng miễn phí. Biên bản trực tiếp, dịch giọng nói một bước, và nhân bản giọng cần Ling API key của riêng bạn (dịch vụ LLM của Ant Group). Một giờ họp tốn khoảng ¥0.15 tới ¥1 RMB, và Ling cung cấp ¥10 tín dụng miễn phí mỗi tháng, đủ cho 10 tới 50 giờ.

**Máy Mac Intel, Windows, Linux, Android**: Nhận dạng giọng nói chạy trên đám mây và cần key dịch vụ AI; âm thanh được gửi thành từng đoạn tới Ming của Ling hoặc dịch vụ bạn chọn (OpenRouter, ZenMux, v.v.). Bản ghi âm và bản ghi cuộc họp vẫn chỉ ở trên thiết bị của bạn.

Ứng dụng Mac chỉ hỏi một quyền khi bạn dùng tính năng tương ứng, và mọi thứ khác vẫn hoạt động bình thường nếu bạn từ chối:

| Quyền | Dùng để làm gì | Không có nó |
|---|---|---|
| Ghi âm thanh hệ thống (Ghi màn hình & âm thanh hệ thống) | Nghe âm thanh hệ thống để làm phụ đề; không bao giờ ghi màn hình | Phụ đề và biên bản không hoạt động |
| Micrô | Giữ để nói hoặc **Rảnh tay** cho phiên dịch; nhấn **Bật micrô** để nghe phòng họp | Không nói để dịch được hoặc nghe phòng được |
| Giám sát đầu vào | Phát hiện phím ⌥ phải (không chặn hay ghi lại phím khác) | Chuyển sang phím tắt `⌃`/`⌘` để bỏ qua quyền này |
| Mật khẩu quản trị viên | Cài micrô ảo BlackHole 2ch (hỏi một lần) | Phía bên kia không nghe được phiên dịch; mọi thứ khác vẫn hoạt động |

- **Mạng minh bạch**: Chỉ kết nối internet để dịch (`translate.googleapis.com`), dịch vụ AI bạn cấu hình (như `api.ant-ling.com`), tải driver BlackHole đã được Apple công chứng (kiểm chứng bằng SHA-256), và kiểm tra GitHub mỗi ngày một lần để tìm bản cập nhật. Không phân tích, không theo dõi, và không máy chủ riêng của chúng tôi.
- **Lưu trữ cục bộ**: Bản ghi và bản ghi âm nằm trong `~/Library/Application Support/LiveSubs`. Key và mẫu giọng của bạn chỉ tài khoản hệ thống hiện tại của bạn đọc được và bị loại khỏi Time Machine và nhật ký.
- **Ẩn khỏi chụp màn hình**: Trên Mac, chia sẻ màn hình, quay màn hình, và ảnh chụp màn hình không chụp được cửa sổ biên bản. Bạn bật thủ công **Hiện trong chia sẻ màn hình** khi ghi bản mẫu được.

## Mô hình

Bảng dưới đây cho thấy thiết lập trên máy Mac Apple silicon. Khi dùng dịch vụ tự lưu trữ (**Khác (tương thích OpenAI)**), bạn bật **Chỉ gửi âm thanh và văn bản tới dịch vụ của bạn** trong **Cài đặt › Dịch vụ AI** để bỏ qua Google hoàn toàn được.

| Tính năng | Có Ling key | Không có key / dự phòng |
|---|---|---|
| Nhận dạng giọng nói và phát hiện ngôn ngữ | Apple `SpeechAnalyzer` / `SpeechTranscriber` (trên thiết bị); macOS 14.4–15 dùng `SFSpeechRecognizer` (trên thiết bị, cần Đọc chính tả) | Giống vậy |
| Dịch câu đã nói xong | Ling `Ling-3.1-flash` (đổi được sang `Ling-3.0-flash` trong Cài đặt › Dịch vụ AI) | Google Translate → Apple `Translation` (trên thiết bị, chỉ macOS 26) |
| Dịch câu còn đang nói | Google Translate | Hiện nguyên văn cho tới khi bản dịch nguyên câu thay thế |
| Biên bản trực tiếp và bản đầy đủ sau cuộc họp | Ling `Ling-3.1-flash` | Không có |
| Kiểm tra key có dùng được không | Ling `Ling-3.0-tiny` (1 token) | — |
| Phiên dịch: nghe và dịch | Ming `Ming-3.0-audio-flash` (một bước) | Chuỗi nhận dạng + dịch trên thiết bị của Apple ở trên |
| Phiên dịch: giọng ra và nhân bản giọng | Ming `Ming-3.0-tts-0.5B` | Giọng tích hợp của Mac (`AVSpeechSynthesizer`), không nhân bản |
| Nhận diện người nói | WeSpeaker ResNet34-LM (đi kèm, chạy trên thiết bị qua Core ML) | Giống vậy |

## Thiết lập Ling API key

1. Đăng ký và đăng nhập trên [nền tảng mở Ling](https://chat.ant-ling.com/platform/api), tạo một token, và sao chép key bắt đầu bằng `sk-`.
2. Mở **Cài đặt › Dịch vụ AI** trong Cicada (hoặc banner ở đầu cửa sổ biên bản), dán key, và lưu.

**Không đăng ký được Ling?** Ở góc trên bên phải của **Cài đặt › Dịch vụ AI** (hoặc nhấn **Không dùng được Ling?** trong lúc hướng dẫn mở đầu), bạn chuyển sang OpenRouter, ZenMux, OpenAI, hoặc bất kỳ dịch vụ tương thích OpenAI nào (kể cả dịch vụ cục bộ hoặc trong mạng nội bộ như Ollama, vLLM, SGLang, Qwen3-ASR, và Whisper) được.

Sau khi chuyển, biên bản trực tiếp và dịch nguyên câu vẫn hoạt động, và OpenRouter cùng ZenMux cũng dùng được giọng Gemini tự nhiên cho phiên dịch; dịch giọng nói một bước và nhân bản giọng chỉ Ling hỗ trợ. Với dịch vụ tự lưu trữ, biên bản và đặt tên người nói dùng mô hình mạnh hơn của riêng chúng được, hoặc kết nối tới dịch vụ khác (nhập địa chỉ và key của chính nó); tìm kiếm mô hình trong danh sách, hoặc gõ trực tiếp nếu không tìm thấy. Khi Windows, Linux, hoặc Android chuyển sang dịch vụ khác, việc nghe phía bên kia cũng đi qua dịch vụ mới, nên phụ đề chạy chậm hơn Ling 1–2 giây. Nếu kết nối thất bại, Cài đặt cho bạn biết trực tiếp đó là vấn đề key, mô hình, hay proxy (xem [trang thiết lập](https://cicada.indaloop.app/vi/start/#proxy) để biết chi tiết về proxy).

## Yêu cầu & Cài đặt

Gói cài đặt có trên [trang Releases](https://github.com/wquguru/cicada/releases/latest) và [website](https://cicada.indaloop.app/vi/), và bạn kiểm chứng mã kiểm tra SHA-256 đối chiếu `checksums.txt` trong Releases được. Nếu có thắc mắc, hãy liên hệ tác giả [@wquguru](https://x.com/wquguru) trên X.

### Mac

Cần macOS 14.4+ (Apple silicon và Intel). Trên Apple silicon với macOS 14.4–15, trước tiên vào **Cài đặt hệ thống › Bàn phím** để bật **Đọc chính tả** và thêm các ngôn ngữ bạn muốn nghe; macOS 26 dùng trực tiếp mô hình trên thiết bị mới mà không cần Đọc chính tả; máy Mac Intel dùng nhận dạng Ming trên đám mây và cần Ling key.

Tải `Cicada-<version>-macOS-AppleSilicon.dmg` hoặc `Cicada-<version>-macOS-Intel.dmg` và kéo Cicada vào Applications (kiểm chứng bằng `shasum -a 256 Cicada-*.dmg`). Ứng dụng đã được Apple ký và công chứng, nên mở bằng nhấp đúp. Làm theo hướng dẫn mở đầu để cấp quyền và thử cuộc họp mẫu.

<p align="center">
  <img src="docs/onboarding.png" width="640" alt="Bước 2 của hướng dẫn mở đầu phát một cuộc họp mẫu hai người với phụ đề song ngữ trực tiếp">
</p>

### Windows

Cần Windows 10 2004+ (x64 hoặc Snapdragon ARM64). Tải gói cài đặt và nhấp đúp để cài mà không cần quyền quản trị. Nếu SmartScreen chặn nó, nhấn **Thông tin thêm › Vẫn chạy**. Khi dùng phiên dịch, hướng dẫn đưa bạn qua việc cài micrô ảo VB-Cable miễn phí.

### Linux

Cần Ubuntu 22.04 hoặc 24.04 bản desktop (x86_64 hoặc arm64). Tải `Cicada-<version>-Linux.tar.gz` và chạy `tar xzf Cicada-<version>-Linux.tar.gz && cicada-linux/install.sh` trong terminal. Phiên dịch tự tạo một "Micrô Cicada" mà không cần cài driver. Cửa sổ Linux không ẩn khỏi chia sẻ màn hình được, nên cửa sổ biên bản cho biết nó hiện khi bạn chia sẻ màn hình. Để bật **Cài đặt › Chung › Lưu âm thanh cuộc họp**, trước tiên hãy cài các định dạng phương tiện của bên thứ ba của hệ thống (như `ubuntu-restricted-extras`) để cung cấp bộ mã hóa AAC. Bật **Cài đặt › Danh sách từ › Sửa từ nghe nhầm trực tiếp** gửi thêm một yêu cầu văn bản cho mỗi câu.

### Android

Cần Android 10+. Tải và cài `Cicada-<version>-Android.apk`; trên Android 15 trở lên, cho phép cài đặt bị hạn chế trong Thông tin ứng dụng ở lần đầu bạn bật phụ đề nổi. Nó cũng gồm vân tay giọng nói trên thiết bị để phân tách người nói và sửa từ nghe nhầm trực tiếp trong lúc nghe. Ứng dụng gọi điện và họp chặn ghi âm thanh nội bộ trên Android — cứ mở loa ngoài cho cuộc gọi và chuyển sang **Mặt đối mặt**.

## Lộ trình

Theo thứ tự ưu tiên tương đối; cứ mở Issue cho những gì bạn muốn thấy. Xem [docs/ROADMAP.md](docs/ROADMAP.md) để biết chi tiết.

- **Ghi lại lời nói của chính tôi**: Nghe micrô liên tục với khử tiếng vọng trong các cuộc họp để những gì bạn nói trực tiếp cũng vào bản ghi và biên bản.
- **Ký số Windows**: Ký chính thức cho gói cài đặt Windows để loại bỏ hộp thoại bảo mật (ứng dụng Mac đã được công chứng), và key AI trở lại kho khóa hệ thống.
- **Nhận diện người nói trên các nền tảng khác**: Mac đã ghi nhớ giọng đồng nghiệp thường gặp và nhận ra họ trong các cuộc họp sau; Windows, Linux và Android tiếp theo.
- **Biên bản không cần key**: Tạo biên bản cuộc họp trên các máy Mac được hỗ trợ bằng mô hình trên thiết bị của Apple.
- **Android lên kho ứng dụng**: Không còn cài APK thủ công.
- **iPhone và iPad**: Bắt đầu với nghe phòng họp, phiên dịch mặt đối mặt, và bản ghi cuộc họp.

## Gỡ cài đặt

Thoát Cicada và kéo nó từ thư mục Applications vào Thùng rác. Bản ghi cuộc họp và bản ghi âm nằm trong `~/Library/Application Support/LiveSubs` và xóa thủ công được nếu không còn cần. Để xóa cài đặt, chạy:

```bash
defaults delete com.wquguru.cicada
```

## Phát triển

Ứng dụng Mac chỉ cần Xcode Command Line Tools (`xcode-select --install`) và không có phụ thuộc bên thứ ba. Trên macOS 27, nếu `SwiftUIMacros` bị báo thiếu, hãy cài Xcode đầy đủ và chạy `sudo xcode-select -s /Applications/Xcode.app`. Để dựng trên các nền tảng khác, xem [windows/README.md](windows/README.md), [linux/README.md](linux/README.md), và [android/README.md](android/README.md).

```bash
scripts/build.sh            # dev build → build/Cicada.app ("Cicada Dev", runs alongside the release app)
open build/Cicada.app
scripts/package.sh          # package release DMG, zip, and SHA-256 checksums
```

Xem [AGENTS.md](AGENTS.md) để biết kiến trúc mã nguồn. Mã nguồn website nằm trong `site/` (được tạo bởi `scripts/site.py`), và lịch sử phát hành nằm trong [CHANGELOG.md](CHANGELOG.md) hoặc trên [nhật ký thay đổi của website](https://cicada.indaloop.app/changelog/).

## Giấy phép

Dự án này được cấp phép theo [Apache-2.0](LICENSE). Driver micrô ảo BlackHole 2ch được cấp phép theo GPL; nó không đi kèm gói cài đặt và được tải từ URL chính thức của nó khi bạn nhấn cài đặt. Mô hình vân tay giọng nói đi kèm là ResNet34-LM của [WeSpeaker](https://github.com/wenet-e2e/wespeaker) huấn luyện trên VoxCeleb (CC BY 4.0), được chuyển sang Core ML bởi `scripts/convert-voiceprint.py`.
