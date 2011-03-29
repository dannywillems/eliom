(* Ocsigen
 * http://www.ocsigen.org
 * Module eliom_client.ml
 * Copyright (C) 2010 Vincent Balat
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

open Eliom_pervasives

let fresh_id = 
  let c = ref 0 in
  fun () -> c := !c+1; "id"^string_of_int !c

let client_sitedata sp =
  let s = Eliom_request_info.get_sitedata_sp sp in
  {Eliom_types.site_dir = s.Eliom_common.site_dir;
   Eliom_types.site_dir_string = s.Eliom_common.site_dir_string;
  }


let client_si s = 
  (* we force all lazys before serialization *)
  {s with
     Eliom_common.si_na_get_params = 
      (let r = Lazy.force s.Eliom_common.si_na_get_params in lazy r);
     Eliom_common.si_persistent_nl_get_params =
      (let r = Lazy.force s.Eliom_common.si_persistent_nl_get_params in lazy r);
     Eliom_common.si_all_get_but_na_nl = 
      (let r = Lazy.force s.Eliom_common.si_all_get_but_na_nl in lazy r);
   }



let eliom_appl_page_data_key :
    ((int64 * int) * Eliom_types.poly list) Polytables.key =
  Polytables.make_key ()

let get_eliom_appl_page_data_ sp = 
  let rc = Eliom_request_info.get_request_cache_sp sp in
  try 
    Polytables.get ~table:rc ~key:eliom_appl_page_data_key
  with Not_found -> 
    let d = ((Eliom_request_info.get_request_id_sp sp, 0), []) in
    Polytables.set ~table:rc ~key:eliom_appl_page_data_key ~value:d;
    d

let wrap (v : 'a) : 'a Eliom_types.data_key =
  let sp = Eliom_common.get_sp () in
  let rc = Eliom_request_info.get_request_cache_sp sp in
  let ((reqnum, num) as n, data) =
    try Polytables.get ~table:rc ~key:eliom_appl_page_data_key
    with Not_found -> ((Eliom_request_info.get_request_id_sp sp, 0), [])
  in
  Polytables.set ~table:rc ~key:eliom_appl_page_data_key
    ~value:((reqnum, num+1), Obj.magic v::data);
  Eliom_types.to_data_key_ n



let wrap_node n = 
  Eliom_types.to_data_key_ (0L, XML.ref_node (HTML5.M.toelt n))


(* let wrap_sp ~sp = wrap ~sp (client_sp sp) *)
