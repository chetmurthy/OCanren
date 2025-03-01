(*
 * OCanren PPX
 * Copyright (C) 2016-2021
 *   Dmitrii Kosarev aka Kakadu, Petr Lozov
 * St.Petersburg State University, JetBrains Research
 *)

open Base
open Ppxlib
open Ppxlib.Ast_builder.Default
open Ppxlib.Ast_helper
open Printf

let notify fmt =
  Printf.ksprintf
    (fun s ->
      let _cmd = Printf.sprintf "notify-send \"%s\"" s in
      let (_ : int) = Caml.Sys.command _cmd in
      ())
    fmt
;;

let ( @@ ) = Caml.( @@ )

module Naming = struct
  let fabst_name = sprintf "g%s"
  let functor_name = sprintf "Distribs_%s"
end

module TypeNameMap = Map.M (String)

module FoldInfo = struct
  (* using fields of structure below we can generate ground type and the logic type *)
  type item =
    { param_name : string
    ; rtyp : core_type
    ; ltyp : core_type
    }

  exception ItemFound of item

  type t = item list

  let param_for_rtyp typ ts =
    let typ_repr =
      Pprintast.core_type Caml.Format.str_formatter typ;
      Caml.Format.flush_str_formatter ()
    in
    try
      List.iter ts ~f:(fun i ->
          let new_repr = Caml.Format.asprintf "%a" Pprintast.core_type i.rtyp in
          if String.equal new_repr typ_repr then raise (ItemFound i));
      None
    with
    | ItemFound i -> Some i
  ;;

  let map ~f (xs : t) = List.map ~f xs
  let empty = []
  let is_empty : t -> bool = List.is_empty

  let extend param_name rtyp ltyp ts =
    (*      printf "extending by `%s`\n%!" param_name;*)
    { param_name; rtyp; ltyp } :: ts
  ;;
end

(* TODO: maybe use Ppxlib.name_type_params_in_td ? *)
let extract_names =
  List.map ~f:(fun typ ->
      match typ.ptyp_desc with
      | Ptyp_var s -> s
      | _ ->
        failwith
          (Caml.Format.asprintf "Don't know what to do with %a" Pprintast.core_type typ))
;;

let nolabel = Asttypes.Nolabel

let get_param_names pcd_args =
  let (Pcstr_tuple pcd_args) = pcd_args in
  extract_names pcd_args
;;

let mangle_construct_name name =
  let low =
    String.mapi
      ~f:(function
        | 0 -> Char.lowercase
        | _ -> Fn.id)
      name
  in
  match low with
  | "val" | "if" | "else" | "for" | "do" | "let" | "open" | "not" -> low ^ "_"
  | _ -> low
;;

let lower_lid lid = Location.{ lid with txt = mangle_construct_name lid.Location.txt }

module Located = struct
  include Located

  (* let mknoloc txt = { txt; loc = Location.none } *)
  let map_loc ~f l = { l with txt = f l.txt }
end

module Exp = struct
  include Exp

  let mytuple ~loc ?(attrs = []) = function
    | [] -> failwith "bad_argument: mytuple"
    | [ x ] -> x
    | xs -> tuple ~loc ~attrs xs
  ;;

  let apply ~loc f = function
    | [] -> f
    | xs -> apply ~loc f xs
  ;;
end

let prepare_distribs ~loc fully_abstract_tname tdecl fmap_decl =
  let open Longident in
  let constructors =
    match tdecl.ptype_kind with
    | Ptype_variant c -> c
    | _ -> failwith "not implemented"
  in
  let gen_module_str = Naming.functor_name fully_abstract_tname in
  [ Str.module_ ~loc
    @@ Mb.mk
         ~loc
         (Located.mk ~loc @@ Some gen_module_str)
         (Mod.apply
            ~loc
            (Mod.ident
               ~loc
               (Located.mk ~loc
               @@ Lident
                    (match tdecl.ptype_params with
                    | [] -> "Fmap"
                    | xs -> sprintf "Fmap%d" (List.length xs))))
            (Mod.structure
               ~loc
               [ fmap_decl
               ; Str.type_
                   ~loc
                   Nonrecursive
                   [ Type.mk
                       ~loc
                       ~params:tdecl.ptype_params
                       ~kind:Ptype_abstract
                       ~priv:Public
                       ~cstrs:[]
                       ~manifest:
                         (Typ.constr ~loc (Located.mk ~loc @@ lident tdecl.ptype_name.txt)
                         @@ List.map ~f:fst tdecl.ptype_params)
                       (Located.mk ~loc "t")
                   ]
               ]))
  ]
  @ List.map constructors ~f:(fun { pcd_name; pcd_args } ->
        let names =
          get_param_names pcd_args |> List.mapi ~f:(fun i _ -> sprintf "a%d" i)
        in
        let body =
          let constr_itself = function
            | [] -> Exp.construct (Located.mk ~loc @@ lident pcd_name.txt) None
            | args ->
              Exp.construct (Located.mk ~loc @@ lident pcd_name.txt)
              @@ Option.some
              @@
              (match args with
              | [ x ] -> x
              | args -> Exp.mytuple ~loc args)
          in
          match names with
          | [] -> constr_itself []
          | [ one ] -> constr_itself [ Exp.ident ~loc @@ Located.mk ~loc (Lident one) ]
          | xs ->
            (* construct tuple here *)
            constr_itself
              (List.map
                 ~f:(fun name -> Exp.ident ~loc @@ Located.mk ~loc (Lident name))
                 xs)
        in
        let body =
          let distrib_lid =
            Located.mk ~loc Longident.(Ldot (Lident gen_module_str, "distrib"))
          in
          [%expr inj [%e Exp.apply ~loc (Exp.ident ~loc distrib_lid) [ nolabel, body ]]]
        in
        Str.value
          ~loc
          Asttypes.Nonrecursive
          [ Vb.mk
              ~loc
              (Pat.var ~loc @@ lower_lid pcd_name)
              (match names with
              | [] ->
                Exp.fun_
                  ~loc
                  nolabel
                  None
                  (Pat.construct ~loc (Located.mk ~loc (Lident "()")) None)
                  body
              | names ->
                List.fold_right
                  ~f:(fun name acc ->
                    Exp.fun_ ~loc nolabel None (Pat.var ~loc @@ Located.mk ~loc name) acc)
                  names
                  ~init:body)
          ])
;;

(* At the moment we genrate fmap here but it is totally fine to reuse the one genrated by GT *)
let prepare_fmap ~loc tdecl =
  [%stri
    let rec fmap _eta =
      GT.gmap [%e Exp.ident ~loc (Located.mk ~loc @@ lident tdecl.ptype_name.txt)] _eta
    ;;]
;;

let mangle_string s = s ^ "_ltyp"

let map_deepest_lident ~f lident =
  let rec helper = function
    | Lident s -> Lident (f s)
    | Ldot (l, s) -> Ldot (l, f s)
    | Lapply (l, r) -> Lapply (l, helper r)
  in
  helper lident
;;

let mangle_lident lident = map_deepest_lident ~f:mangle_string lident

let mangle_core_type typ =
  let rec helper typ =
    let loc = typ.ptyp_loc in
    match typ with
    | [%type: _] -> assert false
    | [%type: GT.string] | [%type: string] -> [%type: GT.string OCanren.logic]
    | [%type: ground] -> [%type: logic]
    | _ ->
      (match typ.ptyp_desc with
      | Ptyp_var s -> typ
      | Ptyp_constr ({ txt; loc }, params) ->
        Typ.constr ~loc { loc; txt = mangle_lident txt } @@ List.map ~f:helper params
      | _ -> failwith "should not happen")
  in
  helper typ
;;

let mangle_reifier typ =
  let rec helper typ =
    let loc = typ.ptyp_loc in
    match typ with
    | [%type: _] -> assert false
    | [%type: string] | [%type: int] -> [%expr OCanren.reify]
    | _ ->
      (match typ.ptyp_desc with
      | Ptyp_var s -> Exp.ident ~loc @@ Located.lident ~loc ("f" ^ s)
      | Ptyp_constr ({ txt; loc }, params) ->
        Exp.apply
          ~loc
          (Exp.ident ~loc
          @@ Located.mk ~loc (map_deepest_lident ~f:(fun s -> s ^ "_reify") txt))
        @@ List.map ~f:(fun typ -> Nolabel, helper typ) params
      | _ -> failwith "should not happen")
  in
  helper typ
;;

let revisit_adt
    ~loc
    ?(gen_gtyp = true)
    ?(gen_ltyp = true)
    ?(gen_reifier = true)
    other_attrs
    tdecl
    ctors
  =
  let der_typ_name = tdecl.ptype_name.Asttypes.txt in
  (* Let's forget about mutal recursion for now *)
  (* For every constructor argument we need to put ground types to parameters *)
  let mapa, full_t =
    List.fold_right
      ~f:(fun cd (n, acc_map, cs) ->
        let n, map2, new_args =
          List.fold_right
            ~f:(fun typ (n, map, args) ->
              match typ.ptyp_desc with
              | Ptyp_any -> assert false
              | Ptyp_var s -> n, map, typ :: args
              | Ptyp_constr ({ txt; loc }, params) ->
                (match FoldInfo.param_for_rtyp typ map with
                | Some { FoldInfo.param_name } -> n, map, ptyp_var ~loc param_name :: args
                | None ->
                  (* We need to mangle whole constructor *)
                  let ltyp = mangle_core_type typ in
                  let new_name = sprintf "a%d" n in
                  ( n + 1
                  , FoldInfo.extend new_name typ ltyp map
                  , ptyp_var ~loc new_name :: args ))
              | _ ->
                (match FoldInfo.param_for_rtyp typ map with
                | Some { FoldInfo.param_name } -> n, map, ptyp_var ~loc param_name :: args
                | None ->
                  let new_name = sprintf "a%d" n in
                  ( n + 1
                  , FoldInfo.extend new_name typ typ map
                  , ptyp_var ~loc new_name :: args )))
            (match cd.pcd_args with
            | Pcstr_tuple tt -> tt
            | Pcstr_record _ -> assert false)
            ~init:(n, acc_map, [])
        in
        let new_args = Pcstr_tuple new_args in
        n, map2, { cd with pcd_args = new_args } :: cs)
      ctors
      ~init:(0, FoldInfo.empty, [])
    |> fun (_, mapa, cs) ->
    mapa, { tdecl with ptype_kind = Ptype_variant cs; ptype_attributes = other_attrs }
  in
  (* now we need to add some parameters if we collected ones *)
  let ans =
    if FoldInfo.is_empty mapa
    then (
      (* let () = print_endline "fully abstract type is not required" in *)
      let fmap_for_typ = prepare_fmap ~loc full_t in
      let ltyp =
        pstr_type
          ~loc
          Recursive
          [ { tdecl with
              ptype_kind = Ptype_abstract
            ; ptype_name = Located.mk ~loc (mangle_string der_typ_name)
            ; ptype_manifest =
                Some
                  (ptyp_constr
                     ~loc
                     (Located.lident ~loc "logic")
                     [ ptyp_constr ~loc (Located.lident ~loc der_typ_name)
                       @@ List.map ~f:fst tdecl.ptype_params
                     ])
            ; ptype_attributes = other_attrs
            }
          ]
      in
      let ground_typ =
        pstr_type ~loc Nonrecursive [ { full_t with ptype_attributes = other_attrs } ]
      in
      let the_reifier =
        let reifiers =
          FoldInfo.map ~f:(fun { FoldInfo.rtyp } -> mangle_reifier rtyp) mapa
        in
        pstr_value
          ~loc
          Recursive
          [ value_binding
              ~loc
              ~pat:(ppat_var ~loc @@ Located.mk ~loc (der_typ_name ^ "_reify"))
              ~expr:
                [%expr
                  fun h ->
                    [%e
                      pexp_apply
                        ~loc
                        (pexp_ident ~loc
                        @@ Located.mk
                             ~loc
                             Longident.(
                               Ldot
                                 ( Lident (Naming.functor_name tdecl.ptype_name.txt)
                                 , "reify" )))
                        (List.map ~f:(fun t -> Nolabel, t) (reifiers @ [ [%expr h] ]))]]
          ]
      in
      List.concat
        [ (if gen_gtyp then [ ground_typ ] else [])
        ; (if gen_ltyp then [ ltyp ] else [])
        ; prepare_distribs der_typ_name ~loc full_t fmap_for_typ
        ; (if gen_reifier then [ the_reifier ] else [])
        ])
    else (
      let functorized_type = Naming.fabst_name full_t.ptype_name.txt in
      let fully_abstract_typ =
        (* a type name for which we will generate `fmap` *)
        let extra_params =
          FoldInfo.map mapa ~f:(fun fi ->
              ( Ast_helper.Typ.var fi.FoldInfo.param_name
              , (Asttypes.NoVariance, Asttypes.NoInjectivity) ))
        in
        let open Location in
        { full_t with
          ptype_params = full_t.ptype_params @ extra_params
        ; ptype_name = { full_t.ptype_name with txt = functorized_type }
        }
      in
      let fully_abstract_tdecl = pstr_type ~loc Nonrecursive [ fully_abstract_typ ] in
      let ground_typ =
        let alias =
          let old_params = List.map ~f:fst tdecl.ptype_params in
          let extra_params = FoldInfo.map ~f:(fun { FoldInfo.rtyp } -> rtyp) mapa in
          Typ.constr
            ~loc
            (Located.lident ~loc fully_abstract_typ.ptype_name.Asttypes.txt)
            (old_params @ extra_params)
        in
        pstr_type
          ~loc
          Recursive
          [ { tdecl with
              ptype_manifest = Some alias
            ; ptype_kind = Ptype_abstract
            ; ptype_attributes = other_attrs
            }
          ]
      in
      let logic_typ =
        let alias =
          let old_params = List.map ~f:fst tdecl.ptype_params in
          let extra_params = FoldInfo.map ~f:(fun { FoldInfo.ltyp } -> ltyp) mapa in
          Typ.constr
            ~loc
            (Located.lident ~loc "logic")
            [ Typ.constr
                ~loc
                (Located.lident ~loc fully_abstract_typ.ptype_name.Asttypes.txt)
                (old_params @ extra_params)
            ]
        in
        pstr_type
          ~loc
          Recursive
          [ { tdecl with
              ptype_kind = Ptype_abstract
            ; ptype_manifest = Some alias
            ; ptype_name = Located.map mangle_string tdecl.ptype_name
            ; ptype_attributes = other_attrs
            }
          ]
      in
      let fmap_for_typ = prepare_fmap ~loc fully_abstract_typ in
      let distribs = prepare_distribs ~loc der_typ_name fully_abstract_typ fmap_for_typ in
      let the_reifier =
        let reifiers =
          FoldInfo.map ~f:(fun { FoldInfo.rtyp } -> mangle_reifier rtyp) mapa
        in
        pstr_value
          ~loc
          Recursive
          [ value_binding
              ~loc
              ~pat:(ppat_var ~loc @@ Located.mk ~loc (der_typ_name ^ "_reify"))
              ~expr:
                [%expr
                  fun eta ->
                    [%e
                      pexp_apply
                        ~loc
                        (pexp_ident ~loc
                        @@ Located.mk
                             ~loc
                             Longident.(
                               Ldot
                                 ( Lident (Naming.functor_name tdecl.ptype_name.txt)
                                 , "reify" )))
                        (List.map ~f:(fun t -> Nolabel, t) (reifiers @ [ [%expr eta] ]))]]
          ]
      in
      (* let () = print_endline "fully abstract type IS required" in *)
      List.concat
        [ [ fully_abstract_tdecl ]
        ; (if gen_gtyp then [ ground_typ ] else [])
        ; (if gen_ltyp then [ logic_typ ] else [])
        ; distribs
        ; (if gen_reifier then [ the_reifier ] else [])
        ])
  in
  ans
;;

let has_to_gen_attr (xs : attributes) =
  (* Format.printf "%s %d: has_to_gen_attr of list len %d\n%!" __FILE__ __LINE__ (List.length xs); *)
  let ours, others =
    List.partition_map xs ~f:(fun ({ attr_name = { txt }; _ } as attr) ->
        if String.equal txt "distrib" then First attr else Second attr)
  in
  assert (List.length ours <= 1);
  match ours with
  | [] -> None
  | [ h ] -> Some (h, others)
  | _ -> failwith "to many distrib attributes"
;;

let suitable_tydecl_wrap ~on_ok ~on_fail tdecl =
  match tdecl.ptype_kind with
  | Ptype_variant cs when Option.is_none tdecl.ptype_manifest ->
    (match has_to_gen_attr tdecl.ptype_attributes with
    | None -> on_fail ()
    | Some (our, other_attrs) ->
      Attribute.explicitly_drop#type_declaration tdecl;
      on_ok cs other_attrs { tdecl with ptype_attributes = [] })
  | _ -> on_fail ()
;;

let suitable_tydecl =
  suitable_tydecl_wrap ~on_ok:(fun _ _ _ -> true) ~on_fail:(fun () -> false)
;;

let str_type_decl ~loc (flg, tdls) =
  let wrap_tydecls loc ts =
    let f tdecl =
      suitable_tydecl_wrap
        tdecl
        ~on_ok:(fun cs other_attrs tdecl -> revisit_adt ~loc other_attrs tdecl cs)
        ~on_fail:(fun () -> failwith "Only variant types without manifest are supported")
    in
    List.concat (List.map ~f ts)
  in
  wrap_tydecls loc tdls
;;

let decorate_with_gt tdecl =
  let loc = tdecl.ptype_loc in
  { tdecl with
    ptype_attributes =
       (attribute
          ~loc
          ~name:(Located.mk ~loc "deriving")
          ~payload:(PStr [%str gt ~options:{ gmap; show; fmt; foldl }])) :: tdecl.ptype_attributes

  }
;;
let decorate_with_attributes tdecl ptype_attributes =
  { tdecl with ptype_attributes }
;;



let is_super_suitable tdecl =
  (* TODO: check that type name is ground *)
  match tdecl.ptype_kind with
  | Ptype_open | Ptype_variant _ | Ptype_record _ -> None
  | Ptype_abstract ->
    (match tdecl.ptype_manifest with
    | None -> None
    | Some typ ->
      (match typ.ptyp_desc with
      | Ptyp_constr ({ txt = Lident id }, args) -> Some (id, args)
      | _ -> None))
;;

let process_main ~loc base_tdecl (rec_, tdecl) =
  let base_generated =
    match base_tdecl.ptype_kind with
    | Ptype_variant cds ->
      revisit_adt
        ~loc:base_tdecl.ptype_loc
        ~gen_gtyp:false
        ~gen_ltyp:false
        ~gen_reifier:false
        []
        base_tdecl
        cds
    | _ -> failwith ""
  in
  let ltyp =
    let oca_logic_ident ~loc = Located.mk ~loc (Ldot (Lident "OCanren", "logic")) in
    let mangle_typ t =
      match t.ptyp_desc with
      | Ptyp_constr ({ txt = Ldot (Lident "GT", s) }, []) ->
        ptyp_constr ~loc (oca_logic_ident ~loc:t.ptyp_loc) [ t ]
      | Ptyp_constr ({ txt = Ldot (path, "ground") }, []) ->
        ptyp_constr ~loc (Located.mk ~loc (Ldot (path, "logic"))) []
      | Ptyp_constr ({ txt = Lident "ground" }, []) ->
        ptyp_constr ~loc (Located.mk ~loc (Lident "logic")) []
      | _ -> t
    in
    let ptype_manifest =
      match tdecl.ptype_manifest with
      | None -> failwith ""
      | Some { ptyp_desc = Ptyp_constr (id, args) } ->
        let ttt = ptyp_constr ~loc id (List.map ~f:mangle_typ args) in
        Option.some (ptyp_constr ~loc (oca_logic_ident ~loc) [ ttt ])
      | t -> t
    in
    let ptype_attributes =
      List.filter tdecl.ptype_attributes ~f:(fun attr ->
          match attr.attr_name.txt with
          | "distrib" -> false
          | _ -> true)
    in
    { tdecl with ptype_name = Located.mk ~loc "logic"; ptype_manifest; ptype_attributes }
  in
  let make_reifier is_rec tdecl =
    let rec helper typ =
      match typ.ptyp_desc with
      | Ptyp_constr ({ txt = Lident "ground" }, []) -> [%expr reify]
      | Ptyp_constr ({ txt = Ldot (Lident "GT", _) }, []) -> [%expr OCanren.reify]
      | Ptyp_constr ({ txt = Ldot (m, "ground") }, args) ->
        pexp_ident ~loc (Located.mk ~loc (Ldot (m, "reify")))
      | _ -> [%expr reify]
    in
    let body =
      match tdecl.ptype_manifest with
      | None -> failwith "should not happen"
      | Some m ->
        (match m.ptyp_desc with
        | Ptyp_constr ({ txt = Lident id }, args) ->
          let foo =
            pexp_ident ~loc
            @@ Located.mk ~loc Longident.(Ldot (Lident (Naming.functor_name id), "reify"))
          in
          pexp_apply ~loc foo (List.map ~f:(fun s -> Nolabel, helper s) args)
        | _ -> failwith "should not happen")
    in
    pstr_value
      ~loc
      is_rec
      [ value_binding ~loc ~pat:[%pat? reify] ~expr:[%expr fun eta -> [%e body] eta] ]
  in
  List.concat
    [ [ pstr_type ~loc Nonrecursive [ base_tdecl ] ]
    ; base_generated
    ; [ pstr_type ~loc rec_ [ decorate_with_attributes tdecl base_tdecl.ptype_attributes ] ]
    ; [ pstr_type ~loc rec_ [ decorate_with_attributes ltyp base_tdecl.ptype_attributes  ] ]
    ; [ make_reifier rec_ tdecl ]
    ]
;;

let process_super_suitable ~loc revhist (rec_, tdecl) =
  let base_tname, args = Option.value_exn (is_super_suitable tdecl) in
  let base_tdecl =
    try
      List.find_map_exn revhist ~f:(fun si ->
          Pprintast.structure_item Caml.Format.std_formatter si;
          match si.pstr_desc with
          | Pstr_type (_, [ tdecl ]) ->
            notify
              "Looking for basic type called '%s': testing %s"
              base_tname
              tdecl.ptype_name.txt;
            if String.equal tdecl.ptype_name.txt base_tname then Some tdecl else None
          | _ -> None)
    with
    | Not_found_s _ -> failwithf "basic type called '%s' not found" base_tname ()
  in
  process_main ~loc base_tdecl (rec_, tdecl)
;;
