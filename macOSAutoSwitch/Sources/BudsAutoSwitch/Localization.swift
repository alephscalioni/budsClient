import Foundation

func L(_ portuguese: String, _ english: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("pt") == true ? portuguese : english
}
