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

[
  (variable_name)
  (simple_variable_name)
  (special_variable_name)
  (variable_ref)
] @variable

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
  "="
  "+="
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

(ERROR) @error
