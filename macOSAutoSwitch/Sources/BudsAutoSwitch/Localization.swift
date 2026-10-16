import Foundation

/// UI languages, resolved from the Mac's preferred language list.
enum AppLanguage: String, CaseIterable {
    case english = "en", portuguese = "pt", spanish = "es", french = "fr", german = "de", italian = "it",
         dutch = "nl", swedish = "sv", polish = "pl", turkish = "tr", russian = "ru", ukrainian = "uk",
         arabic = "ar", hindi = "hi", indonesian = "id", vietnamese = "vi", thai = "th", japanese = "ja",
         korean = "ko", chineseSimplified = "zh-Hans", chineseTraditional = "zh-Hant"

    static var current: AppLanguage { resolve(Locale.preferredLanguages) }

    /// First preferred language that is supported; English otherwise.
    static func resolve(_ preferred: [String]) -> AppLanguage {
        for identifier in preferred {
            let id = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if id.hasPrefix("zh") {
                let traditional = id.contains("hant") || id.hasSuffix("-tw") || id.hasSuffix("-hk") || id.hasSuffix("-mo")
                return traditional ? .chineseTraditional : .chineseSimplified
            }
            let code = id.split(separator: "-").first.map(String.init) ?? id
            let normalized = code == "in" ? "id" : code
            if let match = allCases.first(where: { $0.rawValue == normalized }) { return match }
        }
        return .english
    }
}

func L(_ portuguese: String, _ english: String) -> String {
    AppLanguage.current == .portuguese ? portuguese : english
}

/// Strings shown in the connection banner and HUD.
enum LocalizedText {
    case connectedToMac, disconnectedToAnother, left, right, leftEarbud, rightEarbud, caseName, unavailable

    func string(_ language: AppLanguage) -> String {
        let row = Self.table[self]!
        return row[language] ?? row[.english]!
    }

    /// "Disconnected from Mac · Connected to <device>".
    static func disconnected(to device: String, _ language: AppLanguage) -> String {
        "\(disconnectedPrefix[language] ?? disconnectedPrefix[.english]!) · \(connectedToPrefix[language] ?? connectedToPrefix[.english]!) \(device)"
    }

    private static let disconnectedPrefix: [AppLanguage: String] = [
        .english: "Disconnected from Mac", .portuguese: "Desconectado do Mac", .spanish: "Desconectado del Mac",
        .french: "Déconnecté du Mac", .german: "Vom Mac getrennt", .italian: "Disconnesso dal Mac",
        .dutch: "Losgekoppeld van Mac", .swedish: "Frånkopplad från Mac", .polish: "Rozłączono z Makiem",
        .turkish: "Mac'ten ayrıldı", .russian: "Отключено от Mac", .ukrainian: "Відключено від Mac",
        .arabic: "تم قطع الاتصال بالـ Mac", .hindi: "Mac से डिस्कनेक्ट हुआ", .indonesian: "Terputus dari Mac",
        .vietnamese: "Đã ngắt kết nối khỏi Mac", .thai: "ตัดการเชื่อมต่อจาก Mac", .japanese: "Macから切断しました",
        .korean: "Mac 연결 해제됨", .chineseSimplified: "已与 Mac 断开", .chineseTraditional: "已與 Mac 中斷連線"]

    private static let connectedToPrefix: [AppLanguage: String] = [
        .english: "Connected to", .portuguese: "Conectado a", .spanish: "Conectado a", .french: "Connecté à",
        .german: "Verbunden mit", .italian: "Connesso a", .dutch: "Verbonden met", .swedish: "Ansluten till",
        .polish: "Połączono z", .turkish: "Bağlandı:", .russian: "Подключено к", .ukrainian: "Підключено до",
        .arabic: "متصل بـ", .hindi: "से कनेक्ट हुआ:", .indonesian: "Terhubung ke", .vietnamese: "Đã kết nối với",
        .thai: "เชื่อมต่อกับ", .japanese: "接続先:", .korean: "연결됨:", .chineseSimplified: "已连接到",
        .chineseTraditional: "已連線至"]

    private static let table: [LocalizedText: [AppLanguage: String]] = [
        .connectedToMac: [
            .english: "Connected to Mac", .portuguese: "Conectado ao Mac", .spanish: "Conectado al Mac",
            .french: "Connecté au Mac", .german: "Mit Mac verbunden", .italian: "Connesso al Mac",
            .dutch: "Verbonden met Mac", .swedish: "Ansluten till Mac", .polish: "Połączono z Makiem",
            .turkish: "Mac'e bağlandı", .russian: "Подключено к Mac", .ukrainian: "Підключено до Mac",
            .arabic: "متصل بالـ Mac", .hindi: "Mac से कनेक्ट हुआ", .indonesian: "Terhubung ke Mac",
            .vietnamese: "Đã kết nối với Mac", .thai: "เชื่อมต่อกับ Mac แล้ว", .japanese: "Macに接続しました",
            .korean: "Mac에 연결됨", .chineseSimplified: "已连接到 Mac", .chineseTraditional: "已連線至 Mac"],
        .disconnectedToAnother: [
            .english: "another device", .portuguese: "outro dispositivo", .spanish: "otro dispositivo",
            .french: "un autre appareil", .german: "einem anderen Gerät", .italian: "un altro dispositivo",
            .dutch: "een ander apparaat", .swedish: "en annan enhet", .polish: "innym urządzeniem",
            .turkish: "başka bir cihaz", .russian: "другому устройству", .ukrainian: "іншого пристрою",
            .arabic: "جهاز آخر", .hindi: "दूसरा डिवाइस", .indonesian: "perangkat lain",
            .vietnamese: "thiết bị khác", .thai: "อุปกรณ์อื่น", .japanese: "別のデバイス",
            .korean: "다른 기기", .chineseSimplified: "其他设备", .chineseTraditional: "其他裝置"],
        .left: [.english: "L", .portuguese: "E", .spanish: "I", .french: "G", .german: "L", .italian: "S",
                .dutch: "L", .swedish: "V", .polish: "L", .turkish: "Sol", .russian: "Л", .ukrainian: "Л",
                .arabic: "ي", .hindi: "बा", .indonesian: "Kr", .vietnamese: "T", .thai: "ซ", .japanese: "左",
                .korean: "왼", .chineseSimplified: "左", .chineseTraditional: "左"],
        .right: [.english: "R", .portuguese: "D", .spanish: "D", .french: "D", .german: "R", .italian: "D",
                 .dutch: "R", .swedish: "H", .polish: "P", .turkish: "Sağ", .russian: "П", .ukrainian: "П",
                 .arabic: "ن", .hindi: "दा", .indonesian: "Kn", .vietnamese: "P", .thai: "ข", .japanese: "右",
                 .korean: "오", .chineseSimplified: "右", .chineseTraditional: "右"],
        .leftEarbud: [
            .english: "Left earbud", .portuguese: "Esquerdo", .spanish: "Auricular izquierdo",
            .french: "Écouteur gauche", .german: "Linker Ohrhörer", .italian: "Auricolare sinistro",
            .dutch: "Linkeroordopje", .swedish: "Vänster hörsnäcka", .polish: "Lewa słuchawka",
            .turkish: "Sol kulaklık", .russian: "Левый наушник", .ukrainian: "Лівий навушник",
            .arabic: "السماعة اليسرى", .hindi: "बायां ईयरबड", .indonesian: "Earbud kiri",
            .vietnamese: "Tai nghe trái", .thai: "หูฟังข้างซ้าย", .japanese: "左イヤホン",
            .korean: "왼쪽 이어버드", .chineseSimplified: "左耳机", .chineseTraditional: "左耳機"],
        .rightEarbud: [
            .english: "Right earbud", .portuguese: "Direito", .spanish: "Auricular derecho",
            .french: "Écouteur droit", .german: "Rechter Ohrhörer", .italian: "Auricolare destro",
            .dutch: "Rechteroordopje", .swedish: "Höger hörsnäcka", .polish: "Prawa słuchawka",
            .turkish: "Sağ kulaklık", .russian: "Правый наушник", .ukrainian: "Правий навушник",
            .arabic: "السماعة اليمنى", .hindi: "दायां ईयरबड", .indonesian: "Earbud kanan",
            .vietnamese: "Tai nghe phải", .thai: "หูฟังข้างขวา", .japanese: "右イヤホン",
            .korean: "오른쪽 이어버드", .chineseSimplified: "右耳机", .chineseTraditional: "右耳機"],
        .caseName: [
            .english: "Case", .portuguese: "Estojo", .spanish: "Estuche", .french: "Boîtier", .german: "Ladecase",
            .italian: "Custodia", .dutch: "Case", .swedish: "Fodral", .polish: "Etui", .turkish: "Kutu",
            .russian: "Кейс", .ukrainian: "Кейс", .arabic: "العلبة", .hindi: "केस", .indonesian: "Case",
            .vietnamese: "Hộp sạc", .thai: "เคส", .japanese: "ケース", .korean: "케이스",
            .chineseSimplified: "充电盒", .chineseTraditional: "充電盒"],
        .unavailable: [
            .english: "unavailable", .portuguese: "indisponível", .spanish: "no disponible",
            .french: "indisponible", .german: "nicht verfügbar", .italian: "non disponibile",
            .dutch: "niet beschikbaar", .swedish: "otillgänglig", .polish: "niedostępne",
            .turkish: "kullanılamıyor", .russian: "недоступно", .ukrainian: "недоступно",
            .arabic: "غير متاح", .hindi: "उपलब्ध नहीं", .indonesian: "tidak tersedia",
            .vietnamese: "không khả dụng", .thai: "ไม่พร้อมใช้งาน", .japanese: "利用不可",
            .korean: "사용 불가", .chineseSimplified: "不可用", .chineseTraditional: "無法使用"]
    ]
}
