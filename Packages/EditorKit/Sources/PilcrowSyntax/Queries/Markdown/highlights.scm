; Block-level Markdown highlights.
;
; tree-sitter-markdown 0.5.x splits Markdown into a block grammar and a
; separate inline grammar. This file targets the block grammar; inline
; constructs (bold, italic, code spans, inline links) require the inline
; parser to be registered alongside, which we don't do yet.
;
; Capturing whole nodes (rather than child subpatterns) makes this resilient
; across grammar minor versions.

; Headings
(atx_heading) @markup.heading
(setext_heading) @markup.heading

(atx_h1_marker) @punctuation.special
(atx_h2_marker) @punctuation.special
(atx_h3_marker) @punctuation.special
(atx_h4_marker) @punctuation.special
(atx_h5_marker) @punctuation.special
(atx_h6_marker) @punctuation.special
(setext_h1_underline) @punctuation.special
(setext_h2_underline) @punctuation.special

; Block quote
(block_quote) @markup.quote

; Code blocks
(fenced_code_block) @markup.raw.block
(indented_code_block) @markup.raw.block
(fenced_code_block_delimiter) @punctuation.delimiter
(info_string) @markup.heading

; Lists & rules
(list_marker_plus)        @punctuation.special
(list_marker_minus)       @punctuation.special
(list_marker_star)        @punctuation.special
(list_marker_dot)         @punctuation.special
(list_marker_parenthesis) @punctuation.special
(thematic_break)          @punctuation.special

; Links / references
(link_reference_definition) @markup.link
(link_label) @markup.link.label
(link_destination) @markup.link.url
(link_title) @markup.link

; HTML blocks
(html_block) @markup.raw.block
