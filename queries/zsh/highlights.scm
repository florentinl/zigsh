(comment) @comment

[
  (string)
  (raw_string)
  (ansi_c_string)
  (heredoc_body)
  (heredoc_start)
  (heredoc_end)
] @string

(function_definition
  name: (word) @function)

(command_name
  (word) @function)

(glob_pattern) @globbing

[
  (variable_name)
  (simple_variable_name)
  (special_variable_name)
  (variable_ref)
] @variable

(
  (expansion) @variable
  (#match? @variable "^\\$\\{")
)

[
  (number)
  (file_descriptor)
] @number

[
  "case"
  "do"
  "done"
  "elif"
  "else"
  "esac"
  "export"
  "fi"
  "for"
  "function"
  "if"
  "in"
  "select"
  "then"
  "unset"
  "until"
  "while"
] @keyword

[
  "&&"
  "||"
  "|"
  "|&"
  "&"
  ">"
  ">>"
  "<"
  "<<"
  "<<-"
  "<<<"
  "<&"
  ">&"
  "&>"
  "&>>"
  "=="
  "!="
  "=~"
] @operator

[
  "("
  ")"
  "{"
  "}"
  "["
  "]"
  "[["
  "]]"
  "(("
  "))"
  ";"
  ";;"
] @punctuation

(file_redirect
  [
    "<"
    ">"
    ">>"
    "&>"
    "&>>"
    "<&"
    ">&"
    ">|"
    "<&-"
    ">&-"
  ] @redirection)

(herestring_redirect "<<<" @redirection)

(heredoc_redirect
  [
    "<<"
    "<<-"
  ] @redirection)

(command_substitution
  [
    "$("
    "`"
  ] @punctuation)

(process_substitution ["=(" ">(" "<("] @punctuation)

(arithmetic_expansion
  [
    "$(("
    "(("
    "))"
    "$["
  ] @punctuation)

(ERROR) @error
