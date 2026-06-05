## Glossary

Text Input Widget
: Reusable UI control for editing user-provided text.

Single-Line Text Input
: Text input widget constrained to one logical line of text.

Focused Text Input
: Text input widget currently owning keyboard text-edit interaction.

Explicit Widget ID
: Caller-provided stable identifier required for stateful immediate-mode widgets whose state must persist across frames and repeated callsites.

Word Character
: A character forming part of a word boundary. In this codebase, letters (a-z, A-Z), digits (0-9), underscore (_), and all non-ASCII multi-byte characters are word characters. ASCII punctuation (.,;:!?()-[]{}"') is not, enabling standard word-select behavior at punctuation boundaries.