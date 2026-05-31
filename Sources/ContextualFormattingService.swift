import Foundation

// MARK: - ContextualFormattingService

/// O objetivo deste serviço é aplicar deterministicamente as regras de formatação pós-LLM.
/// Cada seção espelha exatamente as regras documentadas.
enum ContextualFormattingService {

    // MARK: - API Principal

    static func format(
        _ text: String,
        precedingText: String?,
        followingText: String?
    ) -> (text: String, leadingSpace: String, trailingSpace: String) {
        // Regra base: Nunca deixar espaço no final do texto colado (strip spaces).
        var processedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !processedText.isEmpty else { return ("", "", "") }

        // Pontuação Duplicada
        processedText = removeDuplicatePunctuation(processedText, following: followingText)

        // Capitalização
        processedText = applyCapitalizationRules(processedText, preceding: precedingText, following: followingText)

        // Espaçamento
        let leadingSpace = computeLeadingSpace(preceding: precedingText)
        let trailingSpace = computeTrailingSpace(following: followingText)

        return (processedText, leadingSpace, trailingSpace)
    }

    // MARK: - Espaçamento

    /// Implementa as regras de espaço antes do texto inserido.
    /// - Se o texto precedente termina com letra ou número → adicionar espaço antes.
    /// - Se o texto precedente termina com `(`, `[`, `{`, `"`, `'` → nenhum espaço antes.
    /// - Inserção entre duas palavras → garantir exatamente um espaço de cada lado, sem duplicar espaços existentes.
    private static func computeLeadingSpace(preceding: String?) -> String {
        guard let preceding = preceding, !preceding.isEmpty else { return "" }
        guard let lastChar = preceding.last else { return "" }

        // Inserção entre duas palavras → garantir exatamente um espaço de cada lado, sem duplicar espaços existentes.
        if lastChar.isWhitespace {
            return ""
        }

        // Se o texto precedente termina com `(`, `[`, `{`, `"`, `'` → nenhum espaço antes.
        if "([{\"'".contains(lastChar) {
            return ""
        }

        // Se o texto precedente termina com letra ou número → adicionar espaço antes.
        if lastChar.isLetter || lastChar.isNumber {
            return " "
        }

        // Caso padrão (ex: após pontuação final): adicionar espaço.
        return " "
    }

    /// Implementa as regras de espaço após o texto inserido.
    /// - Se o texto seguinte começa com `)`, `]`, `}`, `,`, `.`, `?`, `!`, `;`, `:` → nenhum espaço depois.
    /// - Se o texto seguinte começa com letra ou número → adicionar espaço depois.
    /// - Inserção antes de `)`, `]`, `}`, `"`, `'` → nenhum espaço depois.
    private static func computeTrailingSpace(following: String?) -> String {
        guard let following = following, !following.isEmpty else { return "" }
        guard let firstChar = following.first else { return "" }

        // Inserção entre duas palavras → garantir exatamente um espaço de cada lado, sem duplicar espaços existentes.
        if firstChar.isWhitespace {
            return ""
        }

        // Se o texto seguinte começa com pontuações específicas → nenhum espaço depois.
        if ")]},.?!;:'\"".contains(firstChar) {
            return ""
        }

        // Se o texto seguinte começa com letra ou número → adicionar espaço depois.
        if firstChar.isLetter || firstChar.isNumber {
            return " "
        }

        // Caso padrão: separar.
        return " "
    }

    // MARK: - Capitalização

    /// Implementa as regras de letras maiúsculas e minúsculas no início da frase.
    /// - Texto colado após `.`, `?`, `!`, `…` → primeira letra maiúscula.
    /// - Texto colado após `,`, `;`, `:`, `)`, `]`, `}`, `/` → primeira letra minúscula.
    /// - Texto colado no meio de frase (há texto seguinte) → primeira letra minúscula.
    /// - Texto colado no início absoluto do campo (sem texto precedente) → primeira letra maiúscula.
    private static func applyCapitalizationRules(_ text: String, preceding: String?, following: String?) -> String {
        guard let first = text.first else { return text }

        // Se não temos certeza do contexto (ex: texto selecionado para substituir), mantemos a decisão da LLM.
        guard let preceding = preceding else { return text }

        let shouldCapitalize: Bool

        if preceding.isEmpty {
            // Texto colado no início absoluto do campo (sem texto precedente) → primeira letra maiúscula.
            shouldCapitalize = true
        } else {
            let trimmedPreceding = preceding.trimmingCharacters(in: .whitespaces)
            if let lastChar = trimmedPreceding.last {
                if ".?!…".contains(lastChar) {
                    // Texto colado após `.`, `?`, `!`, `…` → primeira letra maiúscula.
                    shouldCapitalize = true
                } else if ",;:)]}/".contains(lastChar) {
                    // Texto colado após `,`, `;`, `:`, `)`, `]`, `}`, `/` → primeira letra minúscula.
                    shouldCapitalize = false
                } else {
                    let hasFollowingWord = following?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    if hasFollowingWord {
                        // Texto colado no meio de frase (há texto seguinte) → primeira letra minúscula.
                        shouldCapitalize = false
                    } else {
                        // Não há regra forte, mantemos o que a LLM enviou.
                        return text
                    }
                }
            } else {
                // O texto precedente era composto apenas de espaços em branco, logo estamos no início visual do campo.
                shouldCapitalize = true
            }
        }

        if shouldCapitalize {
            return first.uppercased() + text.dropFirst()
        } else {
            return first.lowercased() + text.dropFirst()
        }
    }

    // MARK: - Pontuação Duplicada

    /// Implementa as regras de remoção de pontuação redundante gerada pela LLM.
    /// - Texto colado termina com `.`, `?` ou `!` e texto seguinte começa com mesmo sinal → remover duplicado.
    /// - Texto colado termina com `.` e texto seguinte começa com `,` ou `;` → remover o ponto.
    private static func removeDuplicatePunctuation(_ text: String, following: String?) -> String {
        guard let following = following, !following.isEmpty else { return text }
        guard let textLastChar = text.last else { return text }
        guard let follFirstChar = following.trimmingCharacters(in: .whitespaces).first else { return text }

        // Texto colado termina com `.`, `?` ou `!` e texto seguinte começa com mesmo sinal → remover duplicado.
        if ".?!".contains(textLastChar) && textLastChar == follFirstChar {
            return String(text.dropLast())
        }

        // Texto colado termina com `.` e texto seguinte começa com `,` ou `;` → remover o ponto.
        if textLastChar == "." && ",;".contains(follFirstChar) {
            return String(text.dropLast())
        }

        return text
    }

}
