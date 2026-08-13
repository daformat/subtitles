//! Sentence casing for model output.
//!
//! The LibriSpeech-derived models emit unpunctuated ALL CAPS ("GOD AS A DIRECT
//! CONSEQUENCE OF THE SIN"), which is exhausting to read as subtitles. This
//! lowercases and capitalises sentence starts.
//!
//! Applied in the core rather than the renderer so every consumer — overlay,
//! terminal, and any future translation stage — sees the same text without
//! duplicating the rule.
//!
//! **Known limitation:** proper nouns lose their capitals ("HESTER PRYNNE"
//! becomes "hester prynne"). Nothing in the token stream distinguishes a name
//! from any other word. The real fix is a punctuation/truecasing model
//! (sherpa-onnx ships CT-Transformer ones) as a post-stabiliser stage — that
//! would restore both capitals and full stops, at the cost of another model and
//! some latency.

fn capitalise_first(word: &str) -> String {
    let mut chars = word.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

/// Lowercase `s`, capitalising the first word when `sentence_start`, after any
/// sentence-ending punctuation, and the pronoun "I".
///
/// Whitespace is preserved exactly, which matters because tokens arrive with
/// their leading space attached (" GOD") and the caller concatenates them.
pub fn natural_case(s: &str, sentence_start: bool) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len());
    let mut capitalise = sentence_start;
    let mut i = 0;

    while i < chars.len() {
        if chars[i].is_whitespace() {
            out.push(chars[i]);
            i += 1;
            continue;
        }
        let start = i;
        while i < chars.len() && !chars[i].is_whitespace() {
            i += 1;
        }
        let lower: String = chars[start..i].iter().collect::<String>().to_lowercase();

        // "I", plus contractions like "I'm" / "I'll".
        let is_pronoun_i = lower == "i" || lower.starts_with("i'");
        let word = if capitalise || is_pronoun_i {
            capitalise_first(&lower)
        } else {
            lower
        };

        // These models emit no punctuation today, but a truecasing stage later
        // would, and then this keeps working.
        capitalise = word.ends_with('.') || word.ends_with('!') || word.ends_with('?');
        out.push_str(&word);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capitalises_only_the_first_word_of_an_utterance() {
        assert_eq!(
            natural_case(" GOD AS A DIRECT CONSEQUENCE", true),
            " God as a direct consequence"
        );
    }

    #[test]
    fn mid_utterance_stays_lowercase() {
        assert_eq!(natural_case(" OF THE SIN", false), " of the sin");
    }

    #[test]
    fn preserves_leading_space_so_tokens_concatenate() {
        // Tokens arrive as " WORD"; losing the space would run words together.
        let a = natural_case(" HELLO", true);
        let b = natural_case(" WORLD", false);
        assert_eq!(a + &b, " Hello world");
    }

    #[test]
    fn pronoun_i_is_always_capitalised() {
        assert_eq!(natural_case(" I THINK I AM", false), " I think I am");
        assert_eq!(natural_case(" I'M SURE", false), " I'm sure");
    }

    #[test]
    fn punctuation_rearms_capitalisation() {
        assert_eq!(
            natural_case(" DONE. NEXT ONE", true),
            " Done. Next one"
        );
    }

    #[test]
    fn empty_and_whitespace_survive() {
        assert_eq!(natural_case("", true), "");
        assert_eq!(natural_case("   ", true), "   ");
    }
}
