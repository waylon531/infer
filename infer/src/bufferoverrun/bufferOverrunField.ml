(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
module F = Format
module L = Logging

let pp ~pp_lhs ~sep f lhs fn = F.fprintf f "%a%s%s" pp_lhs lhs sep (Typ.Fieldname.get_field_name fn)

let mk, get_type =
  let class_name = "__infer__" in
  let types = ref Typ.Fieldname.Map.empty in
  let mk ?cpp_classname name typ =
    let fieldname =
      match cpp_classname with
      | None ->
          let class_name, field_name = String.rsplit2_exn ~on:'.' (class_name ^ "." ^ name) in
          Typ.Fieldname.make (Typ.Name.Java.from_string class_name) field_name
      | Some classname ->
          Typ.Fieldname.make classname name
    in
    types := Typ.Fieldname.Map.add fieldname typ !types ;
    fieldname
  in
  let get_type fn = Typ.Fieldname.Map.find_opt fn !types in
  (mk, get_type)


let java_collection_internal_array = mk "java.collection.elements" Typ.(mk_array void)

let is_java_collection_internal_array fn = Typ.Fieldname.equal fn java_collection_internal_array

let c_strlen () =
  if Language.curr_language_is Java then mk "length" Typ.uint else mk "c.strlen" Typ.uint


let cpp_vector_elem_str = "cpp.vector_elem"

let cpp_vector_elem ~vec_typ ~elt_typ =
  let classname =
    match vec_typ.Typ.desc with
    | Typ.Tptr (vec_typ, _) -> (
      match Typ.name vec_typ with
      | None ->
          L.(die InternalError) "Unknown class name of vector `%a`" (Typ.pp_full Pp.text) vec_typ
      | Some t ->
          t )
    | _ ->
        L.(die InternalError) "First parameter of constructor should be a pointer."
  in
  let desc = Typ.Tptr (elt_typ, Typ.Pk_pointer) in
  mk ~cpp_classname:classname cpp_vector_elem_str {Typ.desc; quals= Typ.mk_type_quals ()}


let is_cpp_vector_elem fn = String.equal (Typ.Fieldname.to_simplified_string fn) cpp_vector_elem_str
