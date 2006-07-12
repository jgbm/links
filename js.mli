(* JavaScript code generation *)

val generate_program : Syntax.expression list -> Syntax.expression -> string
val test : unit -> unit 
val run_tests : unit -> unit 

val get_js_lib_url : unit -> string
