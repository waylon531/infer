(*
 * Copyright (c) 2009-2013, Monoidics ltd.
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** The Smallfoot Intermediate Language: Decompiled Expressions *)

open! IStd
module F = Format

(** expression representing the result of decompilation *)
type t =
  | Darray of t * t
  | Dbinop of Binop.t * t * t
  | Dconst of Const.t
  | Dsizeof of Typ.t * t option * Subtype.t
  | Dderef of t
  | Dfcall of t * t list * Location.t * CallFlags.t
  | Darrow of t * Typ.Fieldname.t
  | Ddot of t * Typ.Fieldname.t
  | Dpvar of Pvar.t
  | Dpvaraddr of Pvar.t
  | Dunop of Unop.t * t
  | Dunknown
  | Dretcall of t * t list * Location.t * CallFlags.t

(** Value paths: identify an occurrence of a value in a symbolic heap each expression represents a
    path, with Dpvar being the simplest one *)
type vpath = t option

let eradicate_java () = Config.eradicate && Language.curr_language_is Java

let split_var_clang var_name =
  match String.rsplit2 ~on:'.' var_name with Some (_, name) -> name | _ -> var_name


let builtin_functions_to_string pn =
  if Typ.Procname.equal pn BuiltinDecl.__objc_alloc_no_fail then Some "alloc" else None


let rec pp fmt = function
  | Darray (de1, de2) ->
      F.fprintf fmt "%a[%a]" pp de1 pp de2
  | Dbinop (op, de1, de2) ->
      F.fprintf fmt "(%a%a%a)" pp de1 (Pp.of_string ~f:(Binop.str Pp.text)) op pp de2
  | Dconst (Cfun pn) -> (
    match builtin_functions_to_string pn with
    | Some str ->
        F.pp_print_string fmt str
    | None -> (
        let procname_str = Typ.Procname.to_simplified_string pn in
        match pn with
        | Typ.Procname.ObjC_Cpp {kind= ObjCInstanceMethod}
        | Typ.Procname.ObjC_Cpp {kind= ObjCClassMethod} -> (
          match String.lsplit2 ~on:':' procname_str with
          | Some (base_name, _) ->
              F.pp_print_string fmt base_name
          | None ->
              F.pp_print_string fmt procname_str )
        | _ ->
            F.pp_print_string fmt procname_str ) )
  | Dconst c ->
      (Const.pp Pp.text) fmt c
  | Dderef de ->
      F.fprintf fmt "*%a" pp de
  | Dfcall (fun_dexp, args, _, {cf_virtual= isvirtual}) ->
      let pp_args fmt des =
        if eradicate_java () then (if des <> [] then F.pp_print_string fmt "...")
        else Pp.comma_seq pp fmt des
      in
      let pp_fun fmt = function
        | Dconst (Cfun pname) ->
            let s =
              match pname with
              | Typ.Procname.Java pname_java ->
                  Typ.Procname.Java.get_method pname_java
              | _ ->
                  Typ.Procname.to_string pname
            in
            F.pp_print_string fmt s
        | de ->
            pp fmt de
      in
      let receiver, args' =
        match args with
        | Dpvar pv :: args' when isvirtual && Pvar.is_this pv ->
            (None, args')
        | a :: args' when isvirtual ->
            (Some a, args')
        | _ ->
            (None, args)
      in
      let pp_receiver fmt = function None -> () | Some arg -> F.fprintf fmt "%a." pp arg in
      F.fprintf fmt "%a%a(%a)" pp_receiver receiver pp_fun fun_dexp pp_args args'
  | Darrow (Dpvar pv, f) when Pvar.is_this pv ->
      (* this->fieldname *)
      F.pp_print_string fmt (Typ.Fieldname.to_simplified_string f)
  | Darrow (de, f) ->
      if Language.curr_language_is Java then
        F.fprintf fmt "%a.%s" pp de (Typ.Fieldname.get_field_name f)
      else F.fprintf fmt "%a->%s" pp de (Typ.Fieldname.to_string f)
  | Ddot (Dpvar _, fe) when eradicate_java () ->
      (* static field access *)
      F.pp_print_string fmt (Typ.Fieldname.to_simplified_string fe)
  | Ddot (de, f) ->
      let field_text =
        if Language.curr_language_is Java then Typ.Fieldname.get_field_name f
        else Typ.Fieldname.to_string f
      in
      F.fprintf fmt "%a.%s" pp de field_text
  | Dpvar pv ->
      let var_name = Mangled.to_string (Pvar.get_name pv) in
      let s = if Language.curr_language_is Clang then split_var_clang var_name else var_name in
      F.pp_print_string fmt s
  | Dpvaraddr pv ->
      let var_name = Mangled.to_string (Pvar.get_name pv) in
      let s =
        if eradicate_java () then Pvar.get_simplified_name pv
        else if Language.curr_language_is Clang then split_var_clang var_name
        else Mangled.to_string (Pvar.get_name pv)
      in
      let pp_ampersand fmt = if not (eradicate_java ()) then F.pp_print_string fmt "&" in
      F.fprintf fmt "%t%s" pp_ampersand s
  | Dunop (op, de) ->
      F.fprintf fmt "%s%a" (Unop.to_string op) pp de
  | Dsizeof (typ, _, _) ->
      (Typ.pp_full Pp.text) fmt typ
  | Dunknown ->
      F.pp_print_string fmt "unknown"
  | Dretcall (de, _, _, _) ->
      F.fprintf fmt "returned by %a" pp de


let to_string de = F.asprintf "%a" pp de

(** Pretty print a value path *)
let pp_vpath pe fmt vpath =
  let pp fmt = function Some de -> pp fmt de | None -> () in
  if Pp.equal_print_kind pe.Pp.kind Pp.HTML then
    let pp f vpath = F.fprintf f "{vpath: %a}" pp vpath in
    Io_infer.Html.with_color Orange pp fmt vpath
  else pp fmt vpath


let rec has_tmp_var = function
  | Dpvar pvar | Dpvaraddr pvar ->
      Pvar.is_frontend_tmp pvar || Pvar.is_clang_tmp pvar
  | Dderef dexp | Ddot (dexp, _) | Darrow (dexp, _) | Dunop (_, dexp) | Dsizeof (_, Some dexp, _) ->
      has_tmp_var dexp
  | Darray (dexp1, dexp2) | Dbinop (_, dexp1, dexp2) ->
      has_tmp_var dexp1 || has_tmp_var dexp2
  | Dretcall (dexp, dexp_list, _, _) | Dfcall (dexp, dexp_list, _, _) ->
      has_tmp_var dexp || List.exists ~f:has_tmp_var dexp_list
  | Dconst _ | Dunknown | Dsizeof (_, None, _) ->
      false
