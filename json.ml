open Notfound
open Utility

let show_json = Settings.add_bool("show_json", false, `User)

(*
  SL:
    Having implemented jsonisation of database values, I'm now
    unsure if this is what we really want. From a security point
    of view it certainly isn't a very good idea to pass this kind of
    information to the client.
*)
let json_of_db (db, params) =
  let driver = db#driver_name() in
  let (name, args) = Value.parse_db_string params in
    "{_db:{driver:\"" ^ driver ^ "\",name:\"" ^ name ^ "\", args:\"" ^ args ^ "\"}}"

(*
WARNING:
  May need to be careful about free type variables / aliases in row
*)
let json_of_table ((db, params), name, keys, row) =
  let json_of_key k = "[" ^ (mapstrcat ", " (fun x -> x) k) ^ "]" in
  let json_of_keylist ks = "[" ^ (mapstrcat ", " json_of_key ks) ^ "]" in
    "{_table:{db:'" ^ json_of_db (db, params) ^ "',name:\"" ^ name ^
      "\",row:\"" ^ Types.string_of_datatype (`Record row) ^
      "\",keys:\"" ^ json_of_keylist keys ^ "\"}}"

let js_dq_escape_string str = 
  (* escape for placement in double-quoted string *)
  Str.global_replace (Str.regexp_string "\"") "\\\""
    (Str.global_replace (Str.regexp_string "\n") "\\n"
       (Str.global_replace (Str.regexp_string "\\") "\\\\"
          str))

(** Escape the argument for inclusion in a double-quoted string. *)
let js_dq_escape_char =
  function
    '"' -> "\\\""
  | '\\' -> "\\\\"
  | ch -> String.make 1 ch

let jsonize_location : Ir.location -> string = function
  | `Client  -> "client"
  | `Server  -> "server"
  | `Native  -> "native"
  | `Unknown -> "unknown"

let rec jsonize_value : Value.t -> string = function
  | `PrimitiveFunction _
  | `Continuation _
      as r ->
      failwith ("Can't yet jsonize " ^ Value.string_of_value r);
  | `FunctionPtr (f, fvs) ->
    let (_, _, _, location) = Tables.find Tables.fun_defs f in
    let location = jsonize_location location in
    let env_string =
      match fvs with
      | None     -> ""
      | Some fvs -> ", environment:" ^ jsonize_value fvs in

    "{func:\"" ^ Js.var_name_var f ^ "\"," ^
    " location:\"" ^ location ^ "\"" ^ env_string ^ "}"
  | `ClientFunction name -> "{func:\"" ^ name ^ "\"}"
  | #Value.primitive_value as p -> jsonize_primitive p
  | `Variant (label, value) -> Printf.sprintf "{\"_label\":\"%s\",\"_value\":%s}" label (jsonize_value value)
  | `Record fields ->
      "{" ^
        mapstrcat "," (fun (kj, v) -> "\"" ^ kj ^ "\":" ^ jsonize_value v) fields
      ^ "}"
  | `List [] -> "[]"
  | `List (elems) ->
      "[" ^ String.concat "," (List.map jsonize_value elems) ^ "]"
  | `Pid (pid, `Client) ->
    let process = Proc.Proc.get_client_process pid in
    let messages = Proc.Mailbox.pop_all_messages_for pid in
    "{pid:" ^ string_of_int pid ^ "," ^
    " process:" ^ jsonize_value process ^ "," ^
    " messages:" ^ jsonize_value (`List messages) ^
    "}"
  | `Pid (pid, _) -> failwith "Cannot yet jsonize non-client proceses"
  | `Socket _ -> failwith "Cannot jsonize sockets"
and jsonize_primitive : Value.primitive_value -> string = function
  | `Bool value -> string_of_bool value
  | `Int value -> string_of_int value
  | `Float value -> string_of_float' value
  | `Char c -> "{\"_c\":\"" ^ (js_dq_escape_char c) ^"\"}"
  | `Database db -> json_of_db db
  | `Table t -> json_of_table t
  | `XML xmlitem -> json_of_xmlitem xmlitem
  | `String s -> "\"" ^ js_dq_escape_string s ^ "\""
and json_of_xmlitem = function
  | Value.Text s ->
      "[\"TEXT\",\"" ^ js_dq_escape_string (s) ^ "\"]"
  | Value.Node (tag, xml) ->
      let attrs, body =
        List.fold_right (fun xmlitem (attrs, body) ->
            match xmlitem with
            | Value.Attr (label, value) ->
              if label = "key" then
                begin
                  let key = int_of_string value in
                  let hs = EventHandlers.find key in
                  ("eventHandlers: " ^ "\"" ^ js_dq_escape_string (jsonize_value hs) ^ "\"") :: attrs, body
                end
              else
                ("\"" ^label ^ "\" : " ^ "\"" ^ js_dq_escape_string value ^ "\"") :: attrs, body
            | _ -> attrs, (json_of_xmlitem xmlitem) :: body) xml ([], [])
      in
        "[\"ELEMENT\",\"" ^ tag ^ "\",{" ^ String.concat "," attrs
        ^"},[" ^ String.concat "," body ^ "]]"
  | Value.Attr _ -> assert false

let encode_continuation (cont : Value.continuation) : string =
  Value.marshal_continuation cont

let jsonize_value value =
  Debug.if_set show_json
    (fun () -> "jsonize_value => " ^ Value.string_of_value value);
  let rv = jsonize_value value in
    Debug.if_set show_json
      (fun () -> "jsonize_value <= " ^ rv);
    rv

(** [jsonize_call] creates the JSON object representing a client call,
    its server-side continuation, and the complete state of the
    scheduler. Note that [continuation], [name] and [args] arguments are
    all [Value]-style objects, while the last argument,
    [sched_state_json], is already JSONized--a nonuniform interface. This
    is because the [proc.ml] file keeps the scheduler state as an abstract
    type so we can't inspect it here. Consider changing this.
*)
let jsonize_call continuation name args =
  Printf.sprintf
    "{\"__continuation\":\"%s\",\"__name\":\"%s\",\"__args\":[%s]}"
    (encode_continuation continuation)
    name
    (Utility.mapstrcat ", " jsonize_value args)

let parse_json str =
  Jsonparse.parse_json Jsonlex.jsonlex (Lexing.from_string str)

let parse_json_b64 str = parse_json(Utility.base64decode str)
