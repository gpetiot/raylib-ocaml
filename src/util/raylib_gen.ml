open Containers

(* json notes:
 * escape quotes for file endings
 * forward decls *)

(* TODO add descriptions *)

type name = { name : string; cname : string }

module Enum = struct
  type t = { name : name; values : name list; bitmask : bool }

  let def s = String.(lowercase_ascii s |> capitalize_ascii)

  (* find first '_' to skip enum name *)
  let strip_1st cname =
    let start = String.index cname '_' in
    String.drop (start + 1) cname

  let strip_2nd cname = strip_1st cname |> strip_1st

  let rstrip_1st cname =
    let start = String.rindex cname '_' in
    String.take start cname

  let value_of_cname enum_name cname =
    let name =
      match enum_name with
      | "PixelFormat" -> def cname
      | "GamepadAxis" | "GamepadButton" | "MouseCursor" ->
          strip_2nd cname |> def
      | "MouseButton" -> strip_1st cname |> rstrip_1st |> def
      | "NPatchType" ->
          strip_1st cname |> def
          |> String.replace ~sub:"3" ~by:"Three_"
          |> String.replace ~sub:"9" ~by:"Nine_"
      | _ -> strip_1st cname |> def
    in

    { name; cname }

  let name_of_cname cname =
    let bitmask =
      match cname with "ConfigFlag" | "GestureType" -> true | _ -> false
    in
    let name = match cname with "KeyboardKey" -> "Key" | _ -> cname in
    ({ name; cname }, bitmask)

  let of_json json =
    let open Yojson.Basic.Util in
    let name, bitmask = json |> member "name" |> to_string |> name_of_cname in
    let values =
      json |> member "values" |> to_list
      |> List.map (fun value -> member "name" value |> to_string)
      |> List.map (value_of_cname name.name)
    in
    match values with [] -> None | _ -> Some { name; values; bitmask }

  let stubs enum =
    let lower =
      "  let to_int x = Unsigned.UInt32.to_int Ctypes.(coerce t uint32_t x)\n\n"
      ^ "  let of_int i = Ctypes.(coerce uint32_t t (Unsigned.UInt32.of_int i))\n\
         end\n\n"
    in

    Printf.sprintf "module %s = struct\n" enum.name.name
    ^ "  type%c t =\n"
    ^ (List.map
         (fun (value : name) ->
           Printf.sprintf "    | %s [@cname \"%s\"]\n" value.name value.cname)
         enum.values
      |> String.concat "")
    ^ Printf.sprintf "  [@@cname \"%s\"] [@@typedef]%s" enum.name.cname
        (if enum.bitmask then " [@@with_bitmask]\n\n" else "\n\n")
    ^ lower

  let itf enum =
    let lower =
      "\n  val to_int : t -> int\n\n" ^ "  val of_int : int -> t\n" ^ "end\n\n"
    in
    Printf.sprintf "module %s : sig\n" enum.name.name
    ^ "  type t =\n"
    ^ (List.map
         (fun (value : name) -> Printf.sprintf "    | %s\n" value.name)
         enum.values
      |> String.concat "")
    ^ lower
end

module Naming = struct
  let is_uppercase = function 'A' .. 'Z' -> true | _ -> false

  let to_snake_case s =
    let rec aux first acc = function
      | hd :: _ as lst when is_uppercase hd && not first ->
          aux true ('_' :: acc) lst
      | hd :: tl when is_uppercase hd && first ->
          (* eg the p in getFPS *)
          aux first (Char.lowercase_ascii hd :: acc) tl
      | hd :: tl -> aux false (hd :: acc) tl
      | [] -> List.rev acc |> String.of_list
    in
    aux false [] (String.to_list s)
end

module Type = struct
  module StrTbl = Hashtbl.Make (String)

  module Typing = struct
    type t =
      | C of string
      | Ray of string
      | Forw_decl of name
      | Array of int * string
      | Ptr of t

    let is_builtin = function
      | "int" | "uint" | "char" | "uchar" | "float" | "bool" | "void" | "short"
      | "ushort" ->
          true
      | _ -> false

    let array_eq (asize, atyp) (bsize, btyp) =
      String.equal atyp btyp && asize = bsize

    let type_tbl = StrTbl.create 1

    (* special treatment for typedefs *)
    let () = StrTbl.replace type_tbl "Texture2D" "Texture"

    let () = StrTbl.replace type_tbl "Quaternion" "Vector4"

    let of_cname cname arr =
      let convert a =
        if is_builtin a then match a with "uint" -> C "int" | _ -> C a
        else
          match StrTbl.find_opt type_tbl a with
          | Some name -> Ray name
          | None -> Forw_decl { name = Naming.to_snake_case a; cname = a }
      in

      let rec aux acc = function
        | "unsigned" :: tl -> aux (acc ^ "u") tl
        | "\\*" :: _ | "\\*\\*" :: _ -> failwith "Something after pointer"
        | [ "*" ] -> Ptr (convert acc)
        | [ "**" ] -> Ptr (Ptr (convert acc))
        | str :: tl -> aux (acc ^ str) tl
        | [] -> convert acc
      in
      match (arr, aux "" @@ String.split_on_char ' ' cname) with
      | Some count, C typ -> Array (count, typ)
      | None, ret -> ret
      | Some _, _ -> failwith "Array with wrong type"

    let rec name_type ?(ptr = "") = function
      | C name -> name ^ ptr
      | Ray name -> name ^ ".t" ^ ptr
      | Forw_decl name -> name.name ^ ptr
      | Array (size, name) -> Printf.sprintf "%s_array_%i" name size ^ ptr
      | Ptr typ -> name_type ~ptr:(" ptr" ^ ptr) typ
  end

  type field = { name : name; typ : Typing.t }

  (* TODO add description *)

  type t = { name : name; fields : field list }

  let strip_array name =
    match String.index_opt name '[' with
    | None -> (name, None)
    | Some start ->
        let end_ = String.index name ']' in
        let size = String.sub name (start + 1) (end_ - start - 1) in
        (String.take start name, Some (int_of_string size))

  let special_names = function "type" -> "typ" | name -> name

  let field_of_json field =
    let open Yojson.Basic.Util in
    let cname, arr = member "name" field |> to_string |> strip_array in
    let name = Naming.to_snake_case cname |> special_names in

    (* field *)
    let ctyp = member "type" field |> to_string in
    let typ = Typing.of_cname ctyp arr in
    let name = { name; cname } in

    { name; typ }

  let name_of_cname cname = { name = cname; cname }

  let of_json json =
    let open Yojson.Basic.Util in
    let name = json |> member "name" |> to_string |> name_of_cname in
    StrTbl.add Typing.type_tbl name.cname name.name;
    (* hardcode matrix *)
    match name.name with
    | "Matrix" ->
        let fields =
          List.init 16 (fun i ->
              let cname = Printf.sprintf "m%i" i in
              { name = { name = cname; cname }; typ = C "float" })
        in
        { name; fields }
    | _ ->
        let fields =
          json |> member "fields" |> to_list |> List.map field_of_json
        in

        { name; fields }

  let stub_of_field { name; typ } =
    "    " ^ name.name ^ " : " ^ Typing.name_type typ
    ^
    if String.(name.name <> name.cname) then
      Printf.sprintf " [@cname \"%s\"]\n" name.cname
    else "\n"

  let ctor_itf typ =
    if
      List.for_all
        (fun field ->
          match field.typ with
          | Ptr _ | Array _ | Forw_decl _ -> false
          | _ -> true)
        typ.fields
    then
      ( List.map
          (fun field ->
            match field.typ with
            | C name -> name
            | Ray name -> name ^ ".t"
            | _ -> failwith "We should be in the other branch")
          typ.fields
      |> fun types ->
        List.fold_left (fun acc s -> acc ^ s ^ " -> ") "  val create : " types
      )
      ^ "t\n\n"
    else ""

  let getter_itf has_count (field : field) =
    let start = Printf.sprintf "  val %s : t -> " field.name.name in
    if String.mem ~sub:"_count" field.name.name then None
    else
      match field.typ with
      | Ptr (Forw_decl _) -> None
      | Ptr typ when has_count field.name.name ->
          Some (start ^ Typing.name_type typ ^ " CArray.t\n\n")
      | C _ | Ray _ | Ptr _ -> Some (start ^ Typing.name_type field.typ ^ "\n\n")
      | Forw_decl _ -> None
      | Array (size, typ) ->
          (* arbitrary cutoff at 10 *)
          if size > 10 then None
          else Some (start ^ typ ^ " Ctypes_static.carray\n\n")

  let setter_itf has_count (field : field) =
    let start = Printf.sprintf "  val set_%s : t -> " field.name.name in
    let end_ = " -> unit\n\n" in
    if String.mem ~sub:"_count" field.name.name then None
    else
      match field.typ with
      | Ptr (Forw_decl _) -> None
      | Ptr typ when has_count field.name.name ->
          Some (start ^ Typing.name_type typ ^ " CArray.t" ^ end_)
      | C _ | Ray _ | Ptr _ -> Some (start ^ Typing.name_type field.typ ^ end_)
      | Forw_decl _ -> None
      | Array (size, typ) ->
          if size > 10 then None
          else
            Some
              (start
              ^ String.concat " -> " (List.init size (fun _ -> typ))
              ^ end_)

  let itf typ =
    let has_count plural =
      List.exists
        (fun (f : field) ->
          match String.(find ~sub:"_count" f.name.name) with
          | -1 -> false
          | idx -> String.(mem ~sub:(take idx f.name.name) plural))
        typ.fields
    in

    Printf.sprintf "module %s : sig\n" typ.name.name
    ^ "  type t'\n\n" ^ "  type t = t' ctyp\n\n" ^ ctor_itf typ
    (* getters *)
    ^ (List.filter_map (getter_itf has_count) typ.fields |> String.concat "")
    (* setters *)
    ^ (List.filter_map (setter_itf has_count) typ.fields |> String.concat "")
    ^ "end\n\n"

  let stub typ =
    Printf.sprintf "module %s = struct\n" typ.name.name
    (* arrays *)
    ^ (List.filter_map
         (fun field ->
           match field.typ with
           | Typing.Array (size, typ) -> Some (size, typ)
           | _ -> None)
         typ.fields
      |> List.uniq ~eq:Typing.array_eq
      |> List.fold_left
           (fun acc (size, typ) ->
             acc
             ^ Printf.sprintf "  let%%c %s_array_%i = array %i %s\n\n" typ size
                 size typ)
           "")
    (* forward decls *)
    ^ (List.filter_map
         (fun field ->
           match field.typ with
           | Typing.Forw_decl name | Ptr (Forw_decl name) -> Some name
           | _ -> None)
         typ.fields
      |> List.fold_left
           (fun acc { name; cname } ->
             acc
             ^ Printf.sprintf "  let%%c %s = structure \"%s\"\n\n" name cname)
           "")
    ^ "  type%c t = {\n"
    ^ (List.map stub_of_field typ.fields |> String.concat "")
    ^ "  }\n"
    ^ ("  [@@cname \"" ^ typ.name.cname ^ "\"]\n")
    ^ "end\n\n"
end

let () =
  let api = Yojson.Basic.from_file "raylib_api.json" in
  let open Yojson.Basic.Util in
  (* let () = api |> member "structs" |> to_list |> List.iter (fun s ->
   *     s |> member "name" |> to_string |> print_endline
   *   ) in *)
  let enums =
    api |> member "enums" |> to_list |> List.filter_map Enum.of_json
  in
  let stubs =
    (* TODO split rlgl off *)
    "let%c () = header \"#include <raylib.h>\\n#include <rlgl.h>\"\n\n"
    ^ (enums |> List.map Enum.stubs |> String.concat "")
    ^ "let max_material_maps = [%c constant \"MAX_MATERIAL_MAPS\" camlint]\n\n"
    ^ "let max_shader_locations = [%c constant \"MAX_SHADER_LOCATIONS\" \
       camlint]"
  in
  (* print_string stubs; *)
  ignore stubs;
  let itf =
    "(** {1 Constants} *)\n\n"
    ^ (enums |> List.map Enum.itf |> String.concat "")
    ^ "val max_material_maps : int\n\n" ^ "val max_shader_locations : int\n\n"
  in
  (* print_string itf; *)
  ignore itf;

  let types = api |> member "structs" |> to_list |> List.map Type.of_json in
  let stubs =
    "let%c () = header \"#include <raylib.h>\"\n\n"
    ^ (types |> List.map Type.stub |> String.concat "")
  in
  (* print_string stubs; *)
  ignore stubs;
  let itf = types |> List.map Type.itf |> String.concat "" in
  print_string itf;

  ()
(* IO.(with_in "input14.txt" read_lines_l)
 * |> List.map decode |> apply_p1 |> print_int *)