const MAX_DISPLAY_CHARS: usize = 80;

pub fn normalize(value: &str) -> String {
    let cleaned: String = value
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect();
    let collapsed = cleaned.split_whitespace().collect::<Vec<_>>().join(" ");
    let result: String = collapsed.chars().take(MAX_DISPLAY_CHARS).collect();
    if result.is_empty() {
        "Mac".to_string()
    } else {
        result
    }
}
