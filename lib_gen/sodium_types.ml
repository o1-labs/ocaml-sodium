(*
 * Copyright (c) 2015 David Sheets <sheets@alum.mit.edu>
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

module Static = Ctypes_static

module C(F: Ctypes.TYPE) = struct

  module Gen_hash(M: sig
    val scope : string
    val primitive : string
  end) = struct
    type state
    let state : state Static.structure F.typ =
      F.structure ("crypto_"^M.scope^"_"^M.primitive^"_state")

    let () = F.seal state
  end

  module Generichash = Gen_hash(struct
    let scope = "generichash"
    let primitive = "blake2b"
  end)

  module Hmac_sha256 = Gen_hash(struct
    let scope = "auth"
    let primitive = "hmacsha256"
  end)

  module Hmac_sha512 = Gen_hash(struct
    let scope = "auth"
    let primitive = "hmacsha512"
  end)

  module Hmac_sha512256 = struct
    include Hmac_sha512
    let state = F.typedef state "crypto_auth_hmacsha512256_state"
  end

  module One_time_auth = struct
    include Gen_hash(struct
      let scope = "onetimeauth"
      let primitive = "poly1305"
    end)
    let state : state Static.structure F.typ =
      F.typedef state "crypto_onetimeauth_state"
  end
end
