# LighTxt Markdown Preview

Native rendering should stay **clean**, *calm*, and lightweight.

## Supported blocks

- Headings and lists
- [Clickable links](https://example.com)
- `inline code` and fenced code

> This quote should be visually distinct without feeling heavy.

```swift
let message = "Rendered without WebKit"
print(message)
```

| Mode | Memory behavior |
| --- | --- |
| View | Bounded rendered viewport |
| Edit | Bounded editable viewport |

## Wide table regression

| Tool | Calls | What it did |
| :--- | ---: | :---: |
| `tpi.query_artifact_analysis_with_an_extremely_long_unbreakable_identifier_that_must_wrap_inside_column_one` | 043 | Third-A |
| Short | 007 | Third-B |
| `scope|tool` | 011 | Inline pipe remains in one cell |
| Escaped \| prose | 012 | Escaped pipe remains in one cell |
| `unclosed marker | 013 | Unmatched backtick remains a row |

| W1 | W2 | W3 | W4 | W5 | W6 |
| --- | --- | --- | --- | --- | --- |
| another_extremely_long_unbreakable_value_that_must_not_move_any_later_column | W2-A | W3-A | W4-A | W5-A | W6-A |
| tiny | W2-B | W3-B | W4-B | W5-B | W6-B |
