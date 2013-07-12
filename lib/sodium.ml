(*
 * Copyright (c) 2013 David Sheets <sheets@alum.mit.edu>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

open Ctypes
open Unsigned
open PosixTypes

exception VerificationFailure
exception KeyError
exception NonceError

type public
type secret
type channel (* secret *)

type octets = uchar Array.t

module Serialize = struct
  module type S = sig
    type t

    val length : t -> int
    val of_octets : int -> octets -> t
    val into_octets : t -> int -> octets -> unit
  end

  module String : S with type t = string = struct
    type t = string

    let length = String.length

    let of_octets start b =
      let sz = Array.length b in
      let s = String.create (sz - start) in
      for i = start to (sz - 1) do
        s.[i - start] <- char_of_int (UChar.to_int b.(i));
      done; s

    let into_octets s start b = String.iteri (fun i c ->
      b.(i + start) <- UChar.of_int (int_of_char c)
    ) s
  end

  type char_bigarray = (char,
                        Bigarray.int8_unsigned_elt,
                        Bigarray.c_layout) Bigarray.Array1.t
  module Bigarray : S with type t = char_bigarray = struct
    module B = Bigarray
    type t = char_bigarray

    let length = B.Array1.dim

    let of_octets start b =
      let sz = Array.length b in
      let s = B.Array1.create B.char B.c_layout (sz - start) in
      for i = start to (sz - 1) do
        s.{i - start} <- char_of_int (UChar.to_int b.(i));
      done; s

    let into_octets s start b =
      for i = 0 to (length s) - 1 do
        b.(i + start) <- UChar.of_int (int_of_char s.{i});
      done
  end
end

module C = struct
  open Foreign

  let init = foreign "sodium_init" (void @-> returning void)
end

module Random = struct
  (* TODO: support changing generator *)
  module C = struct
    open Foreign
    let stir = foreign "randombytes_stir" (void @-> returning void)
    let gen  = foreign "randombytes_buf"
      (ptr uchar @-> size_t @-> returning void)
  end

  let stir = C.stir

  module Make(T : Serialize.S) = struct
    let gen sz =
      let b = Array.make uchar sz in
      C.gen (Array.start b) (Size_t.of_int sz);
      T.of_octets 0 b
  end
end

module Box = struct
  type 'a box_key  = octets
  type nonce = octets
  type ciphertext  = octets

  type sizes = {
    public_key : int;
    secret_key : int;
    beforenm   : int;
    nonce      : int;
    zero       : int;
    box_zero   : int;
  }

  let crypto_module = "crypto_box"
  let ciphersuite = "curve25519xsalsa20poly1305"
  let impl = "ref"

  (* TODO: alignment? *)
  module C = struct
    open Foreign
    type buffer = uchar Ctypes.ptr
    type box = buffer -> buffer -> ullong -> buffer -> buffer -> buffer -> int

    let const = Printf.sprintf "%s_%s" crypto_module ciphersuite
    let sz_query_type = void @-> returning size_t
    let publickeybytes = foreign (const^"_publickeybytes") sz_query_type
    let secretkeybytes = foreign (const^"_secretkeybytes") sz_query_type
    let beforenmbytes = foreign (const^"_beforenmbytes") sz_query_type
    let noncebytes = foreign (const^"_noncebytes") sz_query_type
    let zerobytes = foreign (const^"_zerobytes") sz_query_type
    let boxzerobytes = foreign (const^"_boxzerobytes") sz_query_type

    let prefix = Printf.sprintf "%s_%s" const impl

    let keypair = foreign (prefix^"_keypair")
      (ptr uchar @-> ptr uchar @-> returning int)

    let box_fn_type = (ptr uchar @-> ptr uchar @-> ullong
                       @-> ptr uchar @-> ptr uchar @-> ptr uchar
                       @-> returning int)

    let box = foreign (prefix) box_fn_type
    let box_open = foreign (prefix^"_open") box_fn_type

    let box_afternm_type =
      (ptr uchar @-> ptr uchar @-> ullong
       @-> ptr uchar @-> ptr uchar @-> returning int)

    let box_beforenm = foreign (prefix^"_beforenm")
      (ptr uchar @-> ptr uchar @-> ptr uchar @-> returning int)
    let box_afternm = foreign (prefix^"_afternm") box_afternm_type

    let box_open_afternm = foreign (prefix^"_open_afternm") box_afternm_type
  end

  let bytes = {
    public_key=Size_t.to_int (C.publickeybytes ());
    secret_key=Size_t.to_int (C.secretkeybytes ());
    beforenm  =Size_t.to_int (C.beforenmbytes ());
    nonce     =Size_t.to_int (C.noncebytes ());
    zero      =Size_t.to_int (C.zerobytes ());
    box_zero  =Size_t.to_int (C.boxzerobytes ());
  }

  let wipe_key k =
    Random.C.gen (Array.start k)
      (Size_t.of_int ((Array.length k) * (sizeof (Array.element_type k))))

  let compare_keys k k' =
    let klen = Array.length k in
    let rec cmp i =
      let c = UChar.compare k.(i) k'.(i) in
      if c = 0 then let j = i+1 in if j=klen then 0 else cmp j
      else c
    in cmp 0

  module Make(T : Serialize.S) = struct
    let read_key sz t =
      let klen = T.length t in
      if klen <> sz then raise KeyError;
      let b = Array.make uchar klen in
      T.into_octets t 0 b;
      b
    let box_read_public_key = read_key bytes.public_key
    let box_read_secret_key = read_key bytes.secret_key
    let box_read_channel_key= read_key bytes.beforenm
    let box_write_key = T.of_octets 0

    let read_nonce t =
      let nlen = T.length t in
      if nlen <> bytes.nonce then raise NonceError;
      let b = Array.make uchar nlen in
      T.into_octets t 0 b;
      b
    let write_nonce n = T.of_octets 0 n

    let read_ciphertext t =
      let clen = T.length t in
      let b = Array.make uchar ~initial:UChar.zero (clen + bytes.box_zero) in
      T.into_octets t bytes.box_zero b;
      b
    let write_ciphertext = T.of_octets bytes.box_zero

    let box_keypair () =
      let pk = Array.make uchar bytes.public_key in
      let sk = Array.make uchar bytes.secret_key in
      let ret = C.keypair (Array.start pk) (Array.start sk) in
      assert (ret = 0); (* TODO: exn *)
      (pk,sk)

    let box sk pk message ~nonce =
      let mlen = T.length message + bytes.zero in
      let c = Array.make uchar mlen in
      let m = Array.make uchar ~initial:UChar.zero mlen in
      T.into_octets message bytes.zero m;
      let ret = C.box (Array.start c) (Array.start m) (ULLong.of_int mlen)
        (Array.start nonce) (Array.start pk) (Array.start sk)
      in
      assert (ret = 0); (* TODO: exn *)
      c

    let box_open sk pk crypt ~nonce =
      let clen = Array.length crypt in
      let m = Array.make uchar clen in
      let ret = C.box_open (Array.start m) (Array.start crypt)
        (ULLong.of_int clen) (Array.start nonce)
        (Array.start pk) (Array.start sk)
      in
      if ret <> 0 then raise VerificationFailure;
      T.of_octets bytes.zero m

    let box_beforenm sk pk =
      let k = Array.make uchar bytes.beforenm in
      let ret = C.box_beforenm (Array.start k) (Array.start pk)
        (Array.start sk) in
      assert (ret = 0); (* TODO: exn *)
      k

    let box_afternm k message ~nonce =
      let mlen = T.length message + bytes.zero in
      let c = Array.make uchar mlen in
      let m = Array.make uchar ~initial:UChar.zero mlen in
      T.into_octets message bytes.zero m;
      let ret = C.box_afternm (Array.start c) (Array.start m)
        (ULLong.of_int mlen) (Array.start nonce) (Array.start k)
      in
      assert (ret = 0); (* TODO: exn *)
      c

    let box_open_afternm k crypt ~nonce =
      let clen = Array.length crypt in
      let m = Array.make uchar clen in
      let ret = C.box_open_afternm (Array.start m) (Array.start crypt)
        (ULLong.of_int clen) (Array.start nonce) (Array.start k)
      in
      if ret <> 0 then raise VerificationFailure;
      T.of_octets bytes.zero m
  end
end
;;
C.init ()
