(* Ocsigen
 * http://www.ocsigen.org
 * http_com.ml Copyright (C) 2005 Denis Berthod
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

(** this module provide a mecanisme to comunicate with some htttp frames*)
open Http_frame
open Lwt

exception Ocsigen_HTTP_parsing_error of string * string
exception Ocsigen_KeepaliveTimeout

(** buffer de comunication permettant la reception et la recup�ration des messages *)
module Com_buffer =
struct
  type t = { mutable buf :string; 
	     mutable read_pos:int; 
	     mutable write_pos:int; 
	     size:int }

  let thread_waiting_read_enable = ref None

  let thread_waiting_write_enable = ref None
             
  (** create a buffer *)
  let create size = { buf=String.create size;
		      read_pos=0;
		      write_pos=0; 
		      size=size }

  (** the number of free byte in the buffer *)
  let nb_free buffer = buffer.size - (buffer.write_pos - buffer.read_pos)

  (** the number of byte in the buffer*)
  let content_length buffer = buffer.write_pos - buffer.read_pos
                         
  (** wait until the buffer has free slot and return the number of free slots*)
  let rec wait_can_write buffer =
    let free = nb_free buffer in
      if free = 0 then
        begin
          let waiting_thread = Lwt.wait () in
          thread_waiting_write_enable := Some waiting_thread;
          waiting_thread >>= (fun () -> 
            thread_waiting_write_enable := None;
            wait_can_write buffer)
        end
      else Lwt.return free

  exception End_of_file         
                
  (** returns a thread that returns when data were received *)
  let receive file_descr buffer =
    try
      wait_can_write buffer >>= (fun free ->
	let temp_buf = String.create free in
	Lwt_unix.read file_descr temp_buf 0 free >>= (fun len ->
          if len = 0 then Lwt.fail End_of_file
          else
            (*copy of the temp buffer in the circular buffer*)
            ((* print_endline temp_buf; *)
             (if buffer.read_pos mod buffer.size > buffer.write_pos mod
	       buffer.size 
             then
	       String.blit temp_buf 0 buffer.buf buffer.write_pos len
             else
	       (let write_to_buf_end = 
		 buffer.size - (buffer.write_pos mod buffer.size) in
	       if write_to_buf_end > len then
                 String.blit temp_buf 0 buffer.buf buffer.write_pos len
	       else
		 (
                  String.blit 
		    temp_buf 0 buffer.buf buffer.write_pos write_to_buf_end;
                  String.blit temp_buf write_to_buf_end buffer.buf 0 
		    (len - write_to_buf_end);
                 )
	       );
	      (* update the buffer *)
	      buffer.write_pos <- buffer.write_pos + len;
	      print_endline "################ thread_waiting_read_enable plein ?";
	      (* if a thread wait for reading wake it up *)
	      (match !thread_waiting_read_enable with
	      |Some thread -> 	      print_endline "################ r�veille";
Lwt.wakeup thread ()
	      |None -> ()
	      );
	      return ()
             )
            )
						     )
				)
    with e -> fail e
	

  let min64 a b = if (Int64.compare a b) < 0 then a else b
  let min3 int1 int2 int3 = min (min int1 int2) int3
  let min3' (int1 : int64) int2 int3 = 
    Int64.to_int (min64 (min64 int1 (Int64.of_int int2)) (Int64.of_int int3))
            
  (** read a given number of bytes from the buffer without destroying the buffer content *)
(* j'enl�ve ; �a n'a pas l'air utilis�... � remettre ???
 let read fd buffer off len () =
    let rec read_aux result read_p rem_len =
      let co = (Int64.compare rem_len 0) in
      if co < 0 
      then assert false 
      else if co = 0 
      then Lwt.return result
      else (
        let available = Int64.sub buffer.write_pos read_p in
        (* convert the positions into buffer indices *)
        let r_buffer_pos = read_p mod buffer.size in
	let co = (Int64.compare available 0) in
	if co < 0 
	then assert false 
	else if co = 0 
	then (* wait until can read more bytes*)
          receive fd buffer >>=
	  (fun () -> read_aux result read_p rem_len)
	else let nb_read = 
	  min3 rem_len available (buffer.size - r_buffer_pos) in
        let string_read = String.sub buffer.buf read_p nb_read in
        read_aux 
	  (result^string_read) 
	  (Int64.add read_p nb_read)
	  (Int64.sub rem_len nb_read)
       )
    in
      if (buffer.read_pos + off> buffer.write_pos) 
      then Lwt.fail (Invalid_argument ("offset out of bound"))
      else read_aux "" (off + buffer.read_pos) len *)

   (** extract a given number bytes in the destructive way from the buffer *)
  let extract fd buffer (len : int64) =
    let rec extract_aux result rem_len =
      if rem_len = Int64.zero 
      then Lwt.return result
      else (
        let available = buffer.write_pos - buffer.read_pos in
        let r_buffer_pos =buffer.read_pos mod buffer.size in
        match available with
        | x when x < 0 -> assert false
        | 0 ->
            (* wait more bytes to read *)
            receive fd buffer >>= (fun () ->
              extract_aux result rem_len)
        | _ -> 
            let nb_extract = 
	      min3' rem_len available (buffer.size - r_buffer_pos) in
            let string_extract = 
	      String.sub buffer.buf buffer.read_pos nb_extract in
            buffer.read_pos <- buffer.read_pos + nb_extract;
            (match !thread_waiting_write_enable with
            |None -> ()
            |Some thread -> Lwt.wakeup thread ()
            );
            extract_aux (result^string_extract) 
	      (Int64.sub rem_len (Int64.of_int nb_extract))
       )
    in try
      extract_aux "" len
    with e -> fail e

(**find the sequence crlfcrlf in the buffer*)
  let rec find buffer ind nb_read =
    function
      |rem_len when rem_len < nb_read -> raise Not_found
      |rem_len ->
          (
          match nb_read with
            |4 ->
                (match (buffer.buf.[ind mod buffer.size ],buffer.buf.[(ind+1) mod buffer.size ],
                                                         buffer.buf.[(ind+2) mod buffer.size],
                                                         buffer.buf.[(ind+3) mod buffer.size]) with
                  |('\r','\n','\r','\n') -> ind + 3
                  |(_,'\r','\n','\r') -> find buffer (ind + 4) 1 (rem_len -4)
                  |(_,_,'\r','\n') -> find buffer (ind +4) 2 (rem_len -4)
                  |(_,_,_,'\r') -> find buffer (ind+4) 3 (rem_len -4)
                  |(_,_,_,_) -> find buffer (ind+4) 4 (rem_len -4)
                )
            |3 ->
                (
                  match (buffer.buf.[ind mod buffer.size],buffer.buf.[(ind+1) mod buffer.size],
                                                          buffer.buf.[(ind +2) mod buffer.size]) with
                    |('\n','\r','\n') -> ind + 2
                    |(_,'\r','\n') -> find buffer (ind + 3) 2 (rem_len -3)
                    |(_,_,'\r') -> find buffer (ind +3) 3 (rem_len -3)
                    |(_,_,_) -> find buffer (ind+3) 4 (rem_len -3)
                )
            |2 -> 
                (
                  match (buffer.buf.[ind mod buffer.size],buffer.buf.[(ind+1) mod buffer.size]) with
                    |('\r','\n') -> ind + 1
                    |(_,'\r') -> find buffer (ind+2) 3 (rem_len -2)
                    |(_,_) -> find buffer (ind+2) 4 (rem_len -2)
                )
            |1 -> 
                (
                  match buffer.buf.[ind mod buffer.size] with
                    |'\n' -> ind
                    |_ -> find buffer (ind+1) 4 (rem_len -1)
                )
            |_ -> assert false
          )
            
  (** returns when the seqence \r\n\r\n is found in the buffer the result is number of char to read *)
  let wait_http_header fd buffer ~keep_alive =
    let rec wait_http_header_aux cur_ind =
      match buffer.write_pos - cur_ind with
        | x when x < 0 -> assert false
        | 0 -> 
           (*wait for more bytes to analyse*)
            receive fd buffer >>= (fun () ->
              wait_http_header_aux cur_ind)
        | available ->
            try
              let end_ind = find buffer cur_ind 4 available in
                Lwt.return (end_ind - buffer.read_pos +1)
            with 
                Not_found ->
                  receive fd buffer >>= (fun () ->
                    wait_http_header_aux 
		      (cur_ind + available - (min available 3)))
    in (* wait_http_header_aux buffer.read_pos 
	  Pour keep-alive timeout je remplace �a par *)
    try
      (if keep_alive
      then
	Lwt.choose
	  [receive fd buffer;
	   (Lwt_unix.sleep (Ocsiconfig.get_keepalive_timeout ()) >>= 
	    (fun () -> fail Ocsigen_KeepaliveTimeout))]
      else return ()) >>= (fun () -> wait_http_header_aux buffer.read_pos)
    with e -> fail e
end


module FHttp_receiver =
  functor(C:Http_frame.HTTP_CONTENT) ->
    struct

      module Http = Http_frame.FHttp_frame (C)
      
      type t = {buffer:Com_buffer.t;fd:Lwt_unix.descr}

      (** create a new receiver *)
      let create ?(buffer_size=8096) fd =
      let buffer = Com_buffer.create buffer_size in
        {buffer=buffer;fd=fd}

      (** convert a string into an header *)
      let http_header_of_string s =
        let lexbuf = Lexing.from_string s in
        try
          Http_parser.header Http_lexer.token lexbuf
        with
        |Parsing.Parse_error -> 
           raise (Ocsigen_HTTP_parsing_error ((Lexing.lexeme lexbuf),s))
         
      (** get an http frame *)
      let get_http_frame receiver ~keep_alive () =
	Com_buffer.wait_http_header ~keep_alive receiver.fd receiver.buffer >>=
	(fun len ->
	  Com_buffer.extract receiver.fd receiver.buffer (Int64.of_int len) >>=
	  (fun string_header ->
            try
              let header = http_header_of_string string_header in
              let body_length=
		try
                  Int64.of_string
		    (Http_frame.Http_header.get_headers_value 
		       header "content-length")
		with
                |_ -> Int64.zero
              in 
	      let rp = receiver.buffer.Com_buffer.read_pos in
	      let wp = receiver.buffer.Com_buffer.write_pos in
	      let sz = receiver.buffer.Com_buffer.size in
	      let bf = receiver.buffer.Com_buffer.buf in
	      let available = 
		if wp >= rp
	      	then String.sub bf rp (wp - rp)
		else (String.sub bf 0 wp)^(String.sub bf rp (sz-rp))
	      in (* Messages.debug ("available: "^available);*)
	      let ct = try 
	        Http_frame.Http_header.get_headers_value header "content-type"
	      with Not_found -> "" in
	      match (Netstring_pcre.string_match 
	   		(Netstring_pcre.regexp ".*multipart.*")) ct 0
	      with 
	        None -> begin 
              let body =
		let comp = Int64.compare body_length Int64.zero in
		if comp < 0 
		then assert false
		else if comp = 0 
		then Lwt.return None
		else
                  Com_buffer.extract receiver.fd receiver.buffer body_length
		    >>= C.content_of_string >>= 
		  (fun c -> Lwt.return (Some c))
              in
              body >>= (fun b ->
                Lwt.return {Http.header=header;Http.content=Http.Ready b}
		       )
		end
		| _ -> (* multipart, create a netstream *) begin
		let netchan = new Netlwtstream.input_descr receiver.fd
		(*match receiver.fd with
		Lwt_unix.Plain fdesc -> new Multipart.input_channel (Lwt_unix.in_channel_of_descr fdesc)
		| Lwt_unix.Encrypted (fdesc,sock) -> new Multipart.input_ssl sock *) in
		Messages.debug "before creation";
		let netstr = new Netlwtstream.input_stream
		    ~init:available ~len:body_length netchan in
		Messages.debug "new Netstream created";
		Lwt.return {Http.header=header;Http.content=Http.Streamed netstr}
		end
            with e -> fail e
          )
        )
      
 
    end


type sender_type = { 
    (** the file descriptor*)
    fd : Lwt_unix.descr;
    (**the mode of the sender Query or Answer*)
    mutable mode : Http_frame.Http_header.http_mode;
    (**protocole to be used : HTTP/1.0 HTTP/1.1*)
    mutable proto : string;
    (**the options to send with each frame, for exemple : server name , ...*)
    mutable headers : (string*string) list
  }

module FHttp_sender =
  functor(C:Http_frame.HTTP_CONTENT) ->
  struct

    module H = Http_frame.Http_header
    
    module Http = Http_frame.FHttp_frame (C)

    module PP = Framepp.Fframepp(C)

    type t = sender_type

(*    (*fonction de dump pour le debuggage*)
    let dump str file =
      let out_chan = open_out file in
      output_string out_chan str;
      close_out out_chan 
*)
    (*fonction d'�criture sur le r�seau*)
      let rec really_write out_ch = function
          | Finished -> Messages.debug "write finished"; Lwt.return ()
	  | Cont (s, next) ->
	     Lwt_unix.write out_ch s 0 (String.length s) >>=
	     ( fun len' ->
	        if (String.length s) = len'
		then really_write out_ch (next ())
		else really_write out_ch (Cont (String.sub s len' ((String.length s)-len'), next))
             )
												    
    (**create a new sender*)
    let create ?(mode=Http_frame.Http_header.Answer) ?(headers=[])
    ?(proto="HTTP/1.1") fd = 
      {fd =fd;mode=mode;headers=headers;proto=proto}

    (**changes the protocol *)
    let change_protocol proto sender =
      sender.proto <- proto

    (**change the header list *)
    let change_headers headers sender =
      sender.headers <- headers

    (**change the mode *)
    let change_mode  mode sender =
      sender.mode <- mode

    (*case non sensitive equality*)
    let non_case_equality s1 s2 =
      (String.lowercase s1) = (String.lowercase s2)

    (* case non sensitive comparison*)
    let non_case_compare s1 s2 =
      String.compare (String.lowercase s1) (String.lowercase s2)

    (* pair order*)
    let pair_order (s11,s12) (s21,s22) =
      if (non_case_compare s11 s21 <= 0)
      then true
      else (non_case_compare s12 s22 <= 0)

    (**adds a header option in the headers list or change the value if the name
    * already exists *)
    let add_header sender name value =
      let rec add_header_aux res =
        function
          |[] -> (name,value)::res
          |(n,v)::tl when (non_case_equality n name) -> (name,value)::(res @ tl)
          |(n,v)::tl -> add_header_aux ((n,v)::res) tl
      in
      sender.headers <- add_header_aux [] sender.headers

    (**removes a header option from the headers list if its exits*)
    let rem_header sender name =
      let rec rem_header_aux res =
        function
          |[] -> res
          |(n,_)::tl when (non_case_equality n name) -> res @ tl
          |(n,v)::tl -> rem_header_aux ((n,v)::res) tl
      in
      sender.headers <- rem_header_aux [] sender.headers

    (** gets the protocol*)
    let get_protocol sender =
      sender.proto

    (**gets the mode*)
    let get_mode sender =
      sender.mode

    (**gets the headers*)
    let get_headers sender =
      sender.headers

    (**gets the value of an header name, raise Not_found if it doesn't exists*)
    let get_header_value sender name =
      let rec get_aux = 
        function
          |[] -> raise Not_found
          |(n,v)::_ when (non_case_equality n name) -> v
          |_::tl -> get_aux tl
      in get_aux sender.headers
    
    (* fusion of the two headers list and add the content-length header*)
    let hds_fusion content_length lst1 lst2 =
      let rec fusion_aux res =
        function
          |([],[]) -> res
          |((n,_)::tl,lst2) when (non_case_equality n "content-length") ->
              fusion_aux res (tl,lst2)
          |(lst1,(n,_)::tl) when (non_case_equality n "content-length") ->
              fusion_aux res (lst1,tl)
          |([],hd::tl) -> fusion_aux (hd::res) ([],tl)
          |(hd::tl,[])-> fusion_aux (hd::res) (tl,[])
          |((n1,_)::tl1,(n2,v2)::tl2) when (non_case_equality n1 n2) -> 
              fusion_aux ((n2,v2)::res) (tl1,tl2)
          |((n1,v1)::tl1,((n2,_)::_ as list2)) when (non_case_compare n1 n2 < 0) ->
              fusion_aux ((n1,v1)::res) (tl1,list2)
          |(lst1,hd2::tl2) -> fusion_aux (hd2::res) (lst1,tl2)
      in
      let length_header =
        match content_length with
        |None -> []
        |Some n -> [("Content-Length", Int64.to_string n)]
      in
      length_header@
        (fusion_aux [] 
        (Sort.list pair_order lst1,Sort.list pair_order lst2)) 


    (** sends the http_frame mode et proto can be overright, the headers are
    * fusioned with those of the sender, the priority is given to the newly
    * defined header when there is a conflict
    * the content-length tag is automaticaly calculated*)
    let send ?mode ?proto ?headers ?meth ?url ?code ?content ?head sender =
      (*creation d'une http_frame*)
      (*creation du header*)
    let md = match mode with None -> sender.mode | Some m -> m in
    let prot = match proto with None -> sender.proto | Some p -> p in
    match content with
      |None -> Lwt.return ()
      |Some c -> (C.stream_of_content c >>=
                  (fun (lon,etag,flux) -> 
		    Lwt.return (hds_fusion (Some lon)
				  (("ETag",etag)::sender.headers) 
				  (match headers with 
				    Some h ->h
				  | None -> []) ) >>=
		    (fun hds -> 
		      let hd = {
			H.mode = md;
			H.meth=meth;
			H.url=url;
			H.code=code;
			H.proto = prot;
			H.headers = hds;
		      } in
		      Messages.debug "writing header";
		      really_write sender.fd 
			(Cont ((Framepp.string_of_header hd), 
			       (fun () -> Finished)))) >>=
		    (fun _ -> match head with 
		    | Some true -> Lwt.return ()
		    | _ -> Messages.debug "writing body"; 
			really_write sender.fd flux)))
  end
