# rdoc-trim book gaps

Transient scratch list (per the `ideas/*.md` graduation rule). During the
ruthless rdoc trim we cut educational prose from yardoc headers. Prose that
looked *book-worthy but whose book coverage we did not confirm* lands here, so a
later book pass can verify the concept is captured before the yardoc version is
gone for good. An entry leaves this list by being confirmed present in the book
(delete it) or by being added to the book (delete it). Empty = nothing
outstanding.

## Open

- **Token accounting → "current context window size."** `Event::Tokens` used to
  carry a worked explanation: `input + cached + cache_creation` = this turn's
  prompt size; `+ output` = tokens consumed *through* this turn (re-processed
  next turn), which is what climbs toward `ContextLengthExceededError`. Trimmed
  to the field list + the exclusive-slices/sum contract. Verify the tokens/
  context chapter walks this formula; if not, add it there.
