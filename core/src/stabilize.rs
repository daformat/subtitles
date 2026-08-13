//! LocalAgreement-2: a token is committed once two consecutive hypotheses agree
//! on it.
//!
//! Spike 0A measured the cost of this at 0 ms p50 / 3 ms p95, with only 4 of 66
//! words ever revised — greedy transducer output is monotonic in practice. It is
//! kept anyway because it is nearly free, and because it is the thing that makes
//! the renderer safe if the engine is ever swapped for one that *does* revise
//! (Whisper, or beam search instead of greedy).

pub struct Stabilizer {
    prev: Vec<String>,
    committed: usize,
}

#[derive(Debug, Default, PartialEq)]
pub struct Update {
    /// Tokens that became final on this step. Append-only, never rewritten.
    pub newly_committed: String,
    /// The still-unstable tail. May change on the next step.
    pub tentative: String,
}

impl Stabilizer {
    pub fn new() -> Self {
        Stabilizer {
            prev: Vec::new(),
            committed: 0,
        }
    }

    pub fn push(&mut self, tokens: &[String]) -> Update {
        // longest prefix on which this hypothesis and the previous one agree
        let mut agreed = 0;
        while agreed < tokens.len().min(self.prev.len()) && tokens[agreed] == self.prev[agreed] {
            agreed += 1;
        }

        // The commit point only ever moves forward: if the engine retracts a
        // token we have already shown, we keep what was shown rather than
        // rewriting history under the reader's eyes.
        let newly_committed = if agreed > self.committed {
            let s = tokens[self.committed..agreed].concat();
            self.committed = agreed;
            s
        } else {
            String::new()
        };

        let tentative = if self.committed < tokens.len() {
            tokens[self.committed..].concat()
        } else {
            String::new()
        };

        self.prev = tokens.to_vec();
        Update {
            newly_committed,
            tentative,
        }
    }

    /// Promote whatever is still tentative to committed, and return it.
    ///
    /// Call this at an endpoint before `reset`. Text that reached the screen but
    /// never got a second agreeing hypothesis would otherwise vanish when the
    /// stream resets — silently truncating the end of any utterance the model was
    /// not confident about.
    pub fn flush(&mut self) -> String {
        if self.committed >= self.prev.len() {
            return String::new();
        }
        let tail = self.prev[self.committed..].concat();
        self.committed = self.prev.len();
        tail
    }

    /// Called when the recognizer stream restarts (endpoint, or a gap in audio).
    pub fn reset(&mut self) {
        self.prev.clear();
        self.committed = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toks(s: &[&str]) -> Vec<String> {
        s.iter().map(|t| t.to_string()).collect()
    }

    #[test]
    fn commits_only_on_second_agreement() {
        let mut s = Stabilizer::new();

        // first sighting: nothing is confirmed yet
        let u = s.push(&toks(&[" HE", "LLO"]));
        assert_eq!(u.newly_committed, "");
        assert_eq!(u.tentative, " HELLO");

        // same prefix again -> commits
        let u = s.push(&toks(&[" HE", "LLO", " WOR"]));
        assert_eq!(u.newly_committed, " HELLO");
        assert_eq!(u.tentative, " WOR");
    }

    #[test]
    fn revision_before_commit_is_absorbed() {
        let mut s = Stabilizer::new();
        s.push(&toks(&[" SEA"]));
        // engine changes its mind while still tentative — nothing was shown as
        // final, so nothing needs rewriting
        let u = s.push(&toks(&[" SEE"]));
        assert_eq!(u.newly_committed, "");
        assert_eq!(u.tentative, " SEE");
    }

    #[test]
    fn committed_text_is_never_retracted() {
        let mut s = Stabilizer::new();
        s.push(&toks(&[" ONE", " TWO"]));
        let u = s.push(&toks(&[" ONE", " TWO"]));
        assert_eq!(u.newly_committed, " ONE TWO");

        // engine now contradicts an already-committed token
        let u = s.push(&toks(&[" ONE", " THREE"]));
        assert_eq!(u.newly_committed, "");
        // commit point holds; we do not un-print what the reader already saw
        assert_eq!(s.committed, 2);
    }

    #[test]
    fn flush_promotes_the_tentative_tail() {
        let mut s = Stabilizer::new();
        s.push(&toks(&[" HOPE"]));
        let u = s.push(&toks(&[" HOPE", " THAN"]));
        assert_eq!(u.newly_committed, " HOPE");
        // " THAN" was displayed but never confirmed; an endpoint must not eat it
        assert_eq!(u.tentative, " THAN");
        assert_eq!(s.flush(), " THAN");
        assert_eq!(s.flush(), "", "flush must be idempotent");
    }

    #[test]
    fn reset_clears_state() {
        let mut s = Stabilizer::new();
        s.push(&toks(&[" A"]));
        s.push(&toks(&[" A"]));
        s.reset();
        let u = s.push(&toks(&[" B"]));
        assert_eq!(u.newly_committed, "");
        assert_eq!(u.tentative, " B");
    }
}
