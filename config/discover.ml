module C = Configurator.V1

(* Opt-in static link of libsodium: set SODIUM_STATIC=1 in the build
   environment and executables linking this library carry no libsodium.so.NN
   runtime dependency. Off by default -- a dynamic link is the normal
   behaviour, this is only for builds that ship their own libsodium.

   The flags go in `library_flags` as -cclib, NOT in `c_library_flags`. The
   latter is passed to ocamlmklib, which builds the shared stub library as
   well as the static one, and a distribution libsodium.a is not compiled
   -fPIC, so a static link there fails outright:

     relocation R_X86_64_PC32 against symbol `randombytes_sysrandom_...'
     can not be used when making a shared object; recompile with -fPIC

   Recorded in the .cmxa instead, the flags apply only when an executable is
   linked, which is the link we actually want static. --push-state/--pop-state
   are GNU ld / lld only, hence Linux-only. *)
let static_requested c =
  match Sys.getenv_opt "SODIUM_STATIC" with
  | None | Some "" | Some "0" ->
      false
  | Some _ -> (
      match C.ocaml_config_var c "system" with
      | Some ("linux" | "linux_elf") ->
          true
      | _ ->
          false )

let library_flags c =
  if not (static_requested c) then []
  else
    [ "-cclib"
    ; "-Wl,--push-state,-Bstatic"
    ; "-cclib"
    ; "-lsodium"
    ; "-cclib"
    ; "-Wl,--pop-state"
    ]

let () =
  C.main ~name:"sodium" (fun c ->
      let default : C.Pkg_config.package_conf =
        { libs = [ "-lsodium" ]; cflags = [] }
      in
      let conf =
        match C.Pkg_config.get c with
        | None -> default
        | Some pc -> (
            match C.Pkg_config.query pc ~package:"libsodium" with
            | None -> default
            | Some deps -> deps)
      in
      let static = static_requested c in
      (* When static, c_library_flags must NOT carry -lsodium: it is passed to
         ocamlmklib (which cannot link a non-PIC archive into the shared stub
         library) and is recorded ahead of this library's own flags at
         executable link time, where a plain -lsodium would resolve against the
         .so before the static block below is reached. The shared stub library
         is left with undefined libsodium symbols, which is fine for a .so. *)
      C.Flags.write_sexp "c_flags.sexp" conf.cflags;
      C.Flags.write_sexp "c_library_flags.sexp"
        (if static then [] else conf.libs);
      C.Flags.write_sexp "library_flags.sexp" (library_flags c);
      (* Raw text, not a sexp list: lib_gen/dune.inc splices this straight into
         a library stanza. `(no_dynlink)` is a dune field, and dune cannot
         switch a field on an environment variable, so the stanza is generated
         instead -- see lib_gen/dune. *)
      let oc = open_out "no_dynlink.sexp" in
      output_string oc (if static then "(no_dynlink)\n" else "\n");
      close_out oc)
