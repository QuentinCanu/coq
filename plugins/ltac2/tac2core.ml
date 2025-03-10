(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open Util
open Pp
open Names
open Genarg
open Tac2env
open Tac2expr
open Tac2entries.Pltac
open Proofview.Notations

let constr_flags =
  let open Pretyping in
  {
    use_coercions = true;
    use_typeclasses = Pretyping.UseTC;
    solve_unification_constraints = true;
    fail_evar = true;
    expand_evars = true;
    program_mode = false;
    polymorphic = false;
  }

let open_constr_no_classes_flags =
  let open Pretyping in
  {
  use_coercions = true;
  use_typeclasses = Pretyping.NoUseTC;
  solve_unification_constraints = true;
  fail_evar = false;
  expand_evars = true;
  program_mode = false;
  polymorphic = false;
  }

(** Standard values *)

module Value = Tac2ffi
open Value

let val_format = Tac2print.val_format
let format = repr_ext val_format

let core_prefix path n = KerName.make path (Label.of_id (Id.of_string_soft n))

let std_core n = core_prefix Tac2env.std_prefix n
let coq_core n = core_prefix Tac2env.coq_prefix n
let ltac1_core n = core_prefix Tac2env.ltac1_prefix n

module Core =
struct

let t_int = coq_core "int"
let t_string = coq_core "string"
let t_array = coq_core "array"
let t_unit = coq_core "unit"
let t_list = coq_core "list"
let t_constr = coq_core "constr"
let t_pattern = coq_core "pattern"
let t_ident = coq_core "ident"
let t_option = coq_core "option"
let t_exn = coq_core "exn"
let t_reference = std_core "reference"
let t_ltac1 = ltac1_core "t"

let c_nil = coq_core "[]"
let c_cons = coq_core "::"

let c_none = coq_core "None"
let c_some = coq_core "Some"

let c_true = coq_core "true"
let c_false = coq_core "false"

end

open Core

let v_unit = Value.of_unit ()
let v_blk = Valexpr.make_block

let of_binder b =
  Value.of_ext Value.val_binder b

let to_binder b =
  Value.to_ext Value.val_binder b

let of_instance u =
  let u = Univ.Instance.to_array (EConstr.Unsafe.to_instance u) in
  Value.of_array (fun v -> Value.of_ext Value.val_univ v) u

let to_instance u =
  let u = Value.to_array (fun v -> Value.to_ext Value.val_univ v) u in
  EConstr.EInstance.make (Univ.Instance.of_array u)

let of_rec_declaration (nas, ts, cs) =
  let binders = Array.map2 (fun na t -> (na, t)) nas ts in
  (Value.of_array of_binder binders,
  Value.of_array Value.of_constr cs)

let to_rec_declaration (nas, cs) =
  let nas = Value.to_array to_binder nas in
  (Array.map fst nas,
  Array.map snd nas,
  Value.to_array Value.to_constr cs)

let of_case_invert = let open Constr in function
  | NoInvert -> ValInt 0
  | CaseInvert {indices} ->
    v_blk 0 [|of_array of_constr indices|]

let to_case_invert = let open Constr in function
  | ValInt 0 -> NoInvert
  | ValBlk (0, [|indices|]) ->
    let indices = to_array to_constr indices in
    CaseInvert {indices}
  | _ -> CErrors.anomaly Pp.(str "unexpected value shape")

let of_result f = function
| Inl c -> v_blk 0 [|f c|]
| Inr e -> v_blk 1 [|Value.of_exn e|]

(** Stdlib exceptions *)

let err_notfocussed =
  Tac2interp.LtacError (coq_core "Not_focussed", [||])

let err_outofbounds =
  Tac2interp.LtacError (coq_core "Out_of_bounds", [||])

let err_notfound =
  Tac2interp.LtacError (coq_core "Not_found", [||])

let err_matchfailure =
  Tac2interp.LtacError (coq_core "Match_failure", [||])

let err_division_by_zero =
  Tac2interp.LtacError (coq_core "Division_by_zero", [||])

(** Helper functions *)

let thaw f = Tac2ffi.apply f [v_unit]

let fatal_flag : unit Exninfo.t = Exninfo.make ()

let has_fatal_flag info = match Exninfo.get info fatal_flag with
  | None -> false
  | Some () -> true

let set_bt info =
  if !Tac2interp.print_ltac2_backtrace then
    Tac2interp.get_backtrace >>= fun bt ->
    Proofview.tclUNIT (Exninfo.add info Tac2entries.backtrace bt)
  else Proofview.tclUNIT info

let throw ?(info = Exninfo.null) e =
  set_bt info >>= fun info ->
  let info = Exninfo.add info fatal_flag () in
  Proofview.tclLIFT (Proofview.NonLogical.raise (e, info))

let fail ?(info = Exninfo.null) e =
  set_bt info >>= fun info ->
  Proofview.tclZERO ~info e

let return x = Proofview.tclUNIT x
let pname s = { mltac_plugin = "coq-core.plugins.ltac2"; mltac_tactic = s }

let wrap f =
  return () >>= fun () -> return (f ())

let wrap_unit f =
  return () >>= fun () -> f (); return v_unit

let catchable_exception = function
  | Logic_monad.Exception _ -> false
  | e -> CErrors.noncritical e

(* Adds ltac2 backtrace
   With [passthrough:false], acts like [Proofview.wrap_exceptions] + Ltac2 backtrace handling
*)
let wrap_exceptions ?(passthrough=false) f =
  try f ()
  with e ->
    let e, info = Exninfo.capture e in
    set_bt info >>= fun info ->
    if not passthrough && catchable_exception e
    then begin if has_fatal_flag info
      then Proofview.tclLIFT (Proofview.NonLogical.raise (e, info))
      else Proofview.tclZERO ~info e
    end
    else Exninfo.iraise (e, info)

let assert_focussed =
  Proofview.Goal.goals >>= fun gls ->
  match gls with
  | [_] -> Proofview.tclUNIT ()
  | [] | _ :: _ :: _ -> throw err_notfocussed

let pf_apply ?(catch_exceptions=false) f =
  let f env sigma = wrap_exceptions ~passthrough:(not catch_exceptions) (fun () -> f env sigma) in
  Proofview.Goal.goals >>= function
  | [] ->
    Proofview.tclENV >>= fun env ->
    Proofview.tclEVARMAP >>= fun sigma ->
    f env sigma
  | [gl] ->
    gl >>= fun gl ->
    f (Proofview.Goal.env gl) (Tacmach.project gl)
  | _ :: _ :: _ ->
    throw err_notfocussed

(** Primitives *)

let define_primitive name arity f =
  Tac2env.define_primitive (pname name) (mk_closure arity f)

let define0 name f = define_primitive name arity_one (fun _ -> f)

let define1 name r0 f = define_primitive name arity_one begin fun x ->
  f (Value.repr_to r0 x)
end

let define2 name r0 r1 f = define_primitive name (arity_suc arity_one) begin fun x y ->
  f (Value.repr_to r0 x) (Value.repr_to r1 y)
end

let define3 name r0 r1 r2 f = define_primitive name (arity_suc (arity_suc arity_one)) begin fun x y z ->
  f (Value.repr_to r0 x) (Value.repr_to r1 y) (Value.repr_to r2 z)
end

let define4 name r0 r1 r2 r3 f = define_primitive name (arity_suc (arity_suc (arity_suc arity_one))) begin fun x0 x1 x2 x3 ->
  f (Value.repr_to r0 x0) (Value.repr_to r1 x1) (Value.repr_to r2 x2) (Value.repr_to r3 x3)
end

let define5 name r0 r1 r2 r3 r4 f = define_primitive name (arity_suc (arity_suc (arity_suc (arity_suc arity_one)))) begin fun x0 x1 x2 x3 x4 ->
  f (Value.repr_to r0 x0) (Value.repr_to r1 x1) (Value.repr_to r2 x2) (Value.repr_to r3 x3) (Value.repr_to r4 x4)
end

(** Printing *)

let () = define1 "print" pp begin fun pp ->
  wrap_unit (fun () -> Feedback.msg_notice pp)
end

let () = define1 "message_of_int" int begin fun n ->
  return (Value.of_pp (Pp.int n))
end

let () = define1 "message_of_string" string begin fun s ->
  return (Value.of_pp (str (Bytes.to_string s)))
end

let () = define1 "message_of_constr" constr begin fun c ->
  pf_apply begin fun env sigma ->
    let pp = Printer.pr_econstr_env env sigma c in
    return (Value.of_pp pp)
  end
end

let () = define1 "message_of_ident" ident begin fun c ->
  let pp = Id.print c in
  return (Value.of_pp pp)
end

let () = define1 "message_of_exn" valexpr begin fun v ->
  Proofview.tclENV >>= fun env ->
  Proofview.tclEVARMAP >>= fun sigma ->
  let pp = Tac2print.pr_valexpr env sigma v (GTypRef (Other Core.t_exn, [])) in
  return (Value.of_pp pp)
end


let () = define2 "message_concat" pp pp begin fun m1 m2 ->
  return (Value.of_pp (Pp.app m1 m2))
end

let () = define0 "format_stop" begin
  return (Value.of_ext val_format [])
end

let () = define1 "format_string" format begin fun s ->
  return (Value.of_ext val_format (Tac2print.FmtString :: s))
end

let () = define1 "format_int" format begin fun s ->
  return (Value.of_ext val_format (Tac2print.FmtInt :: s))
end

let () = define1 "format_constr" format begin fun s ->
  return (Value.of_ext val_format (Tac2print.FmtConstr :: s))
end

let () = define1 "format_ident" format begin fun s ->
  return (Value.of_ext val_format (Tac2print.FmtIdent :: s))
end

let () = define2 "format_literal" string format begin fun lit s ->
  return (Value.of_ext val_format (Tac2print.FmtLiteral (Bytes.to_string lit) :: s))
end

let () = define1 "format_alpha" format begin fun s ->
  return (Value.of_ext val_format (Tac2print.FmtAlpha :: s))
end

let () = define2 "format_kfprintf" closure format begin fun k fmt ->
  let open Tac2print in
  let fold accu = function
  | FmtLiteral _ -> accu
  | FmtString | FmtInt | FmtConstr | FmtIdent -> 1 + accu
  | FmtAlpha -> 2 + accu
  in
  let pop1 l = match l with [] -> assert false | x :: l -> (x, l) in
  let pop2 l = match l with [] | [_] -> assert false | x :: y :: l -> (x, y, l) in
  let arity = List.fold_left fold 0 fmt in
  let rec eval accu args fmt = match fmt with
  | [] -> apply k [of_pp accu]
  | tag :: fmt ->
    match tag with
    | FmtLiteral s ->
      eval (Pp.app accu (Pp.str s)) args fmt
    | FmtString ->
      let (s, args) = pop1 args in
      let pp = Pp.str (Bytes.to_string (to_string s)) in
      eval (Pp.app accu pp) args fmt
    | FmtInt ->
      let (i, args) = pop1 args in
      let pp = Pp.int (to_int i) in
      eval (Pp.app accu pp) args fmt
    | FmtConstr ->
      let (c, args) = pop1 args in
      let c = to_constr c in
      pf_apply begin fun env sigma ->
        let pp = Printer.pr_econstr_env env sigma c in
        eval (Pp.app accu pp) args fmt
      end
    | FmtIdent ->
      let (i, args) = pop1 args in
      let pp = Id.print (to_ident i) in
      eval (Pp.app accu pp) args fmt
    | FmtAlpha ->
      let (f, x, args) = pop2 args in
      Tac2ffi.apply (to_closure f) [of_unit (); x] >>= fun pp ->
      eval (Pp.app accu (to_pp pp)) args fmt
  in
  let eval v = eval (Pp.mt ()) v fmt in
  if Int.equal arity 0 then eval []
  else return (Tac2ffi.of_closure (Tac2ffi.abstract arity eval))
end

(** Array *)

let () = define0 "array_empty" begin
  return (v_blk 0 (Array.of_list []))
end

let () = define2 "array_make" int valexpr begin fun n x ->
  if n < 0 || n > Sys.max_array_length then throw err_outofbounds
  else wrap (fun () -> v_blk 0 (Array.make n x))
end

let () = define1 "array_length" block begin fun (_, v) ->
  return (Value.of_int (Array.length v))
end

let () = define3 "array_set" block int valexpr begin fun (_, v) n x ->
  if n < 0 || n >= Array.length v then throw err_outofbounds
  else wrap_unit (fun () -> v.(n) <- x)
end

let () = define2 "array_get" block int begin fun (_, v) n ->
  if n < 0 || n >= Array.length v then throw err_outofbounds
  else wrap (fun () -> v.(n))
end

let () = define5 "array_blit" block int block int int begin fun (_, v0) s0 (_, v1) s1 l ->
  if s0 < 0 || s0+l > Array.length v0 || s1 < 0 || s1+l > Array.length v1 || l<0 then throw err_outofbounds
  else wrap_unit (fun () -> Array.blit v0 s0 v1 s1 l)
end

let () = define4 "array_fill" block int int valexpr begin fun (_, d) s l v ->
  if s < 0 || s+l > Array.length d || l<0 then throw err_outofbounds
  else wrap_unit (fun () -> Array.fill d s l v)
end

let () = define1 "array_concat" (list block) begin fun l ->
  wrap (fun () -> v_blk 0 (Array.concat (List.map snd l)))
end

(** Ident *)

let () = define2 "ident_equal" ident ident begin fun id1 id2 ->
  return (Value.of_bool (Id.equal id1 id2))
end

let () = define1 "ident_to_string" ident begin fun id ->
  return (Value.of_string (Bytes.of_string (Id.to_string id)))
end

let () = define1 "ident_of_string" string begin fun s ->
  let id = try Some (Id.of_string (Bytes.to_string s)) with _ -> None in
  return (Value.of_option Value.of_ident id)
end

(** Int *)

let () = define2 "int_equal" int int begin fun m n ->
  return (Value.of_bool (m == n))
end

let unop n f = define1 n int begin fun m ->
  return (Value.of_int (f m))
end

let binop n f = define2 n int int begin fun m n ->
  return (Value.of_int (f m n))
end

let () = binop "int_compare" Int.compare
let () = binop "int_add" (+)
let () = binop "int_sub" (-)
let () = binop "int_mul" ( * )
let () = define2 "int_div" int int begin fun m n ->
  if n == 0 then throw err_division_by_zero
  else return (Value.of_int (m / n))
end
let () = define2 "int_mod" int int begin fun m n ->
  if n == 0 then throw err_division_by_zero
  else return (Value.of_int (m mod n))
end
let () = unop "int_neg" (~-)
let () = unop "int_abs" abs

let () = binop "int_asr" (asr)
let () = binop "int_lsl" (lsl)
let () = binop "int_lsr" (lsr)
let () = binop "int_land" (land)
let () = binop "int_lor" (lor)
let () = binop "int_lxor" (lxor)
let () = unop "int_lnot" lnot

(** Char *)

let () = define1 "char_of_int" int begin fun n ->
  wrap (fun () -> Value.of_char (Char.chr n))
end

let () = define1 "char_to_int" char begin fun n ->
  wrap (fun () -> Value.of_int (Char.code n))
end

(** String *)

let () = define2 "string_make" int char begin fun n c ->
  if n < 0 || n > Sys.max_string_length then throw err_outofbounds
  else wrap (fun () -> Value.of_string (Bytes.make n c))
end

let () = define1 "string_length" string begin fun s ->
  return (Value.of_int (Bytes.length s))
end

let () = define3 "string_set" string int char begin fun s n c ->
  if n < 0 || n >= Bytes.length s then throw err_outofbounds
  else wrap_unit (fun () -> Bytes.set s n c)
end

let () = define2 "string_get" string int begin fun s n ->
  if n < 0 || n >= Bytes.length s then throw err_outofbounds
  else wrap (fun () -> Value.of_char (Bytes.get s n))
end

(** Terms *)

(** constr -> constr *)
let () = define1 "constr_type" constr begin fun c ->
  let get_type env sigma =
    let (sigma, t) = Typing.type_of env sigma c in
    let t = Value.of_constr t in
    Proofview.Unsafe.tclEVARS sigma <*> Proofview.tclUNIT t
  in
  pf_apply ~catch_exceptions:true get_type
end

(** constr -> constr *)
let () = define2 "constr_equal" constr constr begin fun c1 c2 ->
  Proofview.tclEVARMAP >>= fun sigma ->
  let b = EConstr.eq_constr sigma c1 c2 in
  Proofview.tclUNIT (Value.of_bool b)
end

let () = define1 "constr_kind" constr begin fun c ->
  let open Constr in
  Proofview.tclEVARMAP >>= fun sigma ->
  Proofview.tclENV >>= fun env ->
  return begin match EConstr.kind sigma c with
  | Rel n ->
    v_blk 0 [|Value.of_int n|]
  | Var id ->
    v_blk 1 [|Value.of_ident id|]
  | Meta n ->
    v_blk 2 [|Value.of_int n|]
  | Evar (evk, args) ->
    let args = Evd.expand_existential sigma (evk, args) in
    v_blk 3 [|
      Value.of_int (Evar.repr evk);
      Value.of_array Value.of_constr (Array.of_list args);
    |]
  | Sort s ->
    v_blk 4 [|Value.of_ext Value.val_sort s|]
  | Cast (c, k, t) ->
    v_blk 5 [|
      Value.of_constr c;
      Value.of_ext Value.val_cast k;
      Value.of_constr t;
    |]
  | Prod (na, t, u) ->
    v_blk 6 [|
      of_binder (na, t);
      Value.of_constr u;
    |]
  | Lambda (na, t, c) ->
    v_blk 7 [|
      of_binder (na, t);
      Value.of_constr c;
    |]
  | LetIn (na, b, t, c) ->
    v_blk 8 [|
      of_binder (na, t);
      Value.of_constr b;
      Value.of_constr c;
    |]
  | App (c, cl) ->
    v_blk 9 [|
      Value.of_constr c;
      Value.of_array Value.of_constr cl;
    |]
  | Const (cst, u) ->
    v_blk 10 [|
      Value.of_constant cst;
      of_instance u;
    |]
  | Ind (ind, u) ->
    v_blk 11 [|
      Value.of_ext Value.val_inductive ind;
      of_instance u;
    |]
  | Construct (cstr, u) ->
    v_blk 12 [|
      Value.of_ext Value.val_constructor cstr;
      of_instance u;
    |]
  | Case (ci, u, pms, c, iv, t, bl) ->
    (* FIXME: also change representation Ltac2-side? *)
    let (ci, c, iv, t, bl) = EConstr.expand_case env sigma (ci, u, pms, c, iv, t, bl) in
    v_blk 13 [|
      Value.of_ext Value.val_case ci;
      Value.of_constr c;
      of_case_invert iv;
      Value.of_constr t;
      Value.of_array Value.of_constr bl;
    |]
  | Fix ((recs, i), def) ->
    let (nas, cs) = of_rec_declaration def in
    v_blk 14 [|
      Value.of_array Value.of_int recs;
      Value.of_int i;
      nas;
      cs;
    |]
  | CoFix (i, def) ->
    let (nas, cs) = of_rec_declaration def in
    v_blk 15 [|
      Value.of_int i;
      nas;
      cs;
    |]
  | Proj (p, c) ->
    v_blk 16 [|
      Value.of_ext Value.val_projection p;
      Value.of_constr c;
    |]
  | Int n ->
    v_blk 17 [|Value.of_uint63 n|]
  | Float f ->
    v_blk 18 [|Value.of_float f|]
  | Array(u,t,def,ty) ->
    v_blk 19 [|of_instance u; Value.of_array Value.of_constr t; Value.of_constr def; Value.of_constr ty|]
  end
end

let () = define1 "constr_make" valexpr begin fun knd ->
  Proofview.tclEVARMAP >>= fun sigma ->
  Proofview.tclENV >>= fun env ->
  let c = match Tac2ffi.to_block knd with
  | (0, [|n|]) ->
    let n = Value.to_int n in
    EConstr.mkRel n
  | (1, [|id|]) ->
    let id = Value.to_ident id in
    EConstr.mkVar id
  | (2, [|n|]) ->
    let n = Value.to_int n in
    EConstr.mkMeta n
  | (3, [|evk; args|]) ->
    let evk = to_evar evk in
    let args = Value.to_array Value.to_constr args in
    EConstr.mkLEvar sigma (evk, Array.to_list args)
  | (4, [|s|]) ->
    let s = Value.to_ext Value.val_sort s in
    EConstr.mkSort (EConstr.Unsafe.to_sorts s)
  | (5, [|c; k; t|]) ->
    let c = Value.to_constr c in
    let k = Value.to_ext Value.val_cast k in
    let t = Value.to_constr t in
    EConstr.mkCast (c, k, t)
  | (6, [|na; u|]) ->
    let (na, t) = to_binder na in
    let u = Value.to_constr u in
    EConstr.mkProd (na, t, u)
  | (7, [|na; c|]) ->
    let (na, t) = to_binder na in
    let u = Value.to_constr c in
    EConstr.mkLambda (na, t, u)
  | (8, [|na; b; c|]) ->
    let (na, t) = to_binder na in
    let b = Value.to_constr b in
    let c = Value.to_constr c in
    EConstr.mkLetIn (na, b, t, c)
  | (9, [|c; cl|]) ->
    let c = Value.to_constr c in
    let cl = Value.to_array Value.to_constr cl in
    EConstr.mkApp (c, cl)
  | (10, [|cst; u|]) ->
    let cst = Value.to_constant cst in
    let u = to_instance u in
    EConstr.mkConstU (cst, u)
  | (11, [|ind; u|]) ->
    let ind = Value.to_ext Value.val_inductive ind in
    let u = to_instance u in
    EConstr.mkIndU (ind, u)
  | (12, [|cstr; u|]) ->
    let cstr = Value.to_ext Value.val_constructor cstr in
    let u = to_instance u in
    EConstr.mkConstructU (cstr, u)
  | (13, [|ci; c; iv; t; bl|]) ->
    let ci = Value.to_ext Value.val_case ci in
    let c = Value.to_constr c in
    let iv = to_case_invert iv in
    let t = Value.to_constr t in
    let bl = Value.to_array Value.to_constr bl in
    EConstr.mkCase (EConstr.contract_case env sigma (ci, c, iv, t, bl))
  | (14, [|recs; i; nas; cs|]) ->
    let recs = Value.to_array Value.to_int recs in
    let i = Value.to_int i in
    let def = to_rec_declaration (nas, cs) in
    EConstr.mkFix ((recs, i), def)
  | (15, [|i; nas; cs|]) ->
    let i = Value.to_int i in
    let def = to_rec_declaration (nas, cs) in
    EConstr.mkCoFix (i, def)
  | (16, [|p; c|]) ->
    let p = Value.to_ext Value.val_projection p in
    let c = Value.to_constr c in
    EConstr.mkProj (p, c)
  | (17, [|n|]) ->
    let n = Value.to_uint63 n in
    EConstr.mkInt n
  | (18, [|f|]) ->
    let f = Value.to_float f in
    EConstr.mkFloat f
  | (19, [|u;t;def;ty|]) ->
    let t = Value.to_array Value.to_constr t in
    let def = Value.to_constr def in
    let ty = Value.to_constr ty in
    let u = to_instance u in
    EConstr.mkArray(u,t,def,ty)
  | _ -> assert false
  in
  return (Value.of_constr c)
end

let () = define1 "constr_check" constr begin fun c ->
  pf_apply begin fun env sigma ->
    try
      let (sigma, _) = Typing.type_of env sigma c in
      Proofview.Unsafe.tclEVARS sigma >>= fun () ->
      return (of_result Value.of_constr (Inl c))
    with e when CErrors.noncritical e ->
      let e = Exninfo.capture e in
      return (of_result Value.of_constr (Inr e))
  end
end

let () = define3 "constr_liftn" int int constr begin fun n k c ->
  let ans = EConstr.Vars.liftn n k c in
  return (Value.of_constr ans)
end

let () = define3 "constr_substnl" (list constr) int constr begin fun subst k c ->
  let ans = EConstr.Vars.substnl subst k c in
  return (Value.of_constr ans)
end

let () = define3 "constr_closenl" (list ident) int constr begin fun ids k c ->
  Proofview.tclEVARMAP >>= fun sigma ->
  let ans = EConstr.Vars.substn_vars sigma k ids c in
  return (Value.of_constr ans)
end

let () = define2 "constr_closedn" int constr begin fun n c ->
  Proofview.tclEVARMAP >>= fun sigma ->
  let ans = EConstr.Vars.closedn sigma n c in
  return (Value.of_bool ans)
end

let () = define3 "constr_occur_between" int int constr begin fun n m c ->
  Proofview.tclEVARMAP >>= fun sigma ->
  let ans = EConstr.Vars.noccur_between sigma n m c in
  return (Value.of_bool (not ans))
end

let () = define1 "constr_case" (repr_ext val_inductive) begin fun ind ->
  Proofview.tclENV >>= fun env ->
  try
    let ans = Inductiveops.make_case_info env ind Sorts.Relevant Constr.RegularStyle in
    return (Value.of_ext Value.val_case ans)
  with e when CErrors.noncritical e ->
    throw err_notfound
end

let () = define2 "constr_constructor" (repr_ext val_inductive) int begin fun (ind, i) k ->
  Proofview.tclENV >>= fun env ->
  try
    let open Declarations in
    let ans = Environ.lookup_mind ind env in
    let _ = ans.mind_packets.(i).mind_consnames.(k) in
    return (Value.of_ext val_constructor ((ind, i), (k + 1)))
  with e when CErrors.noncritical e ->
    throw err_notfound
end

let () = define3 "constr_in_context" ident constr closure begin fun id t c ->
  Proofview.Goal.goals >>= function
  | [gl] ->
    gl >>= fun gl ->
    let env = Proofview.Goal.env gl in
    let sigma = Proofview.Goal.sigma gl in
    let has_var =
      try
        let _ = Environ.lookup_named_val id env in
        true
      with Not_found -> false
    in
    if has_var then
      Tacticals.tclZEROMSG (str "Variable already exists")
    else
      let open Context.Named.Declaration in
      let nenv = EConstr.push_named (LocalAssum (Context.make_annot id Sorts.Relevant, t)) env in
      let (sigma, (evt, _)) = Evarutil.new_type_evar nenv sigma Evd.univ_flexible in
      let (sigma, evk) = Evarutil.new_pure_evar (Environ.named_context_val nenv) sigma evt in
      Proofview.Unsafe.tclEVARS sigma >>= fun () ->
      Proofview.Unsafe.tclSETGOALS [Proofview.with_empty_state evk] >>= fun () ->
      thaw c >>= fun _ ->
      Proofview.Unsafe.tclSETGOALS [Proofview.with_empty_state (Proofview.Goal.goal gl)] >>= fun () ->
      let args = EConstr.identity_subst_val (Environ.named_context_val env) in
      let args = SList.cons (EConstr.mkRel 1) args in
      let ans = EConstr.mkEvar (evk, args) in
      let ans = EConstr.mkLambda (Context.make_annot (Name id) Sorts.Relevant, t, ans) in
      return (Value.of_constr ans)
  | _ ->
    throw err_notfocussed
end

(** preterm -> constr *)
let () = define1 "constr_pretype" (repr_ext val_preterm) begin fun c ->
    let open Pretyping in
    let open Ltac_pretype in
    let pretype env sigma =
      (* For now there are no primitives to create preterms with a non-empty
         closure. I do not know whether [closed_glob_constr] is really the type
         we want but it does not hurt in the meantime. *)
      let { closure; term } = c in
      let vars = {
        ltac_constrs = closure.typed;
        ltac_uconstrs = closure.untyped;
        ltac_idents = closure.idents;
        ltac_genargs = Id.Map.empty;
      } in
      let flags = constr_flags in
      let sigma, t = understand_ltac flags env sigma vars WithoutTypeConstraint term in
      let t = Value.of_constr t in
      Proofview.Unsafe.tclEVARS sigma <*> Proofview.tclUNIT t
    in
    pf_apply ~catch_exceptions:true pretype
end

let () = define2 "constr_binder_make" (option ident) constr begin fun na ty ->
  pf_apply begin fun env sigma ->
  let rel = Retyping.relevance_of_type env sigma ty in
  let na = match na with None -> Anonymous | Some id -> Name id in
  return (Value.of_ext val_binder (Context.make_annot na rel, ty))
  end
end

let () = define1 "constr_binder_name" (repr_ext val_binder) begin fun (bnd, _) ->
  let na = match bnd.Context.binder_name with Anonymous -> None | Name id -> Some id in
  return (Value.of_option Value.of_ident na)
end

let () = define1 "constr_binder_type" (repr_ext val_binder) begin fun (bnd, ty) ->
  return (of_constr ty)
end

let () = define1 "constr_has_evar" constr begin fun c ->
  Proofview.tclEVARMAP >>= fun sigma ->
  let b = Evarutil.has_undefined_evars sigma c in
  Proofview.tclUNIT (Value.of_bool b)
end

(** Patterns *)

let empty_context = Constr_matching.empty_context

let () = define0 "pattern_empty_context" begin
  return (Value.of_ext val_matching_context empty_context)
end

let () = define2 "pattern_matches" pattern constr begin fun pat c ->
  pf_apply begin fun env sigma ->
    let ans =
      try Some (Constr_matching.matches env sigma pat c)
      with Constr_matching.PatternMatchingFailure -> None
    in
    begin match ans with
    | None -> fail err_matchfailure
    | Some ans ->
      let ans = Id.Map.bindings ans in
      let of_pair (id, c) = Value.of_tuple [| Value.of_ident id; Value.of_constr c |] in
      return (Value.of_list of_pair ans)
    end
  end
end

let () = define2 "pattern_matches_subterm" pattern constr begin fun pat c ->
  let open Constr_matching in
  let rec of_ans s = match IStream.peek s with
  | IStream.Nil -> fail err_matchfailure
  | IStream.Cons ({ m_sub = (_, sub); m_ctx }, s) ->
    let ans = Id.Map.bindings sub in
    let of_pair (id, c) = Value.of_tuple [| Value.of_ident id; Value.of_constr c |] in
    let ans = Value.of_tuple [| Value.of_ext val_matching_context m_ctx; Value.of_list of_pair ans |] in
    Proofview.tclOR (return ans) (fun _ -> of_ans s)
  in
  pf_apply begin fun env sigma ->
    let pat = Constr_matching.instantiate_pattern env sigma Id.Map.empty pat in
    let ans = Constr_matching.match_subterm env sigma (Id.Set.empty,pat) c in
    of_ans ans
  end
end

let () = define2 "pattern_matches_vect" pattern constr begin fun pat c ->
  pf_apply begin fun env sigma ->
    let ans =
      try Some (Constr_matching.matches env sigma pat c)
      with Constr_matching.PatternMatchingFailure -> None
    in
    begin match ans with
    | None -> fail err_matchfailure
    | Some ans ->
      let ans = Id.Map.bindings ans in
      let ans = Array.map_of_list snd ans in
      return (Value.of_array Value.of_constr ans)
    end
  end
end

let () = define2 "pattern_matches_subterm_vect" pattern constr begin fun pat c ->
  let open Constr_matching in
  let rec of_ans s = match IStream.peek s with
  | IStream.Nil -> fail err_matchfailure
  | IStream.Cons ({ m_sub = (_, sub); m_ctx }, s) ->
    let ans = Id.Map.bindings sub in
    let ans = Array.map_of_list snd ans in
    let ans = Value.of_tuple [| Value.of_ext val_matching_context m_ctx; Value.of_array Value.of_constr ans |] in
    Proofview.tclOR (return ans) (fun _ -> of_ans s)
  in
  pf_apply begin fun env sigma ->
    let pat = Constr_matching.instantiate_pattern env sigma Id.Map.empty pat in
    let ans = Constr_matching.match_subterm env sigma (Id.Set.empty,pat) c in
    of_ans ans
  end
end

let () = define3 "pattern_matches_goal" bool (list (pair bool pattern)) (pair bool pattern) begin fun rev hp cp ->
  assert_focussed >>= fun () ->
  Proofview.Goal.enter_one begin fun gl ->
  let env = Proofview.Goal.env gl in
  let sigma = Proofview.Goal.sigma gl in
  let concl = Proofview.Goal.concl gl in
  let mk_pattern (b, pat) = if b then Tac2match.MatchPattern pat else Tac2match.MatchContext pat in
  let r = (List.map mk_pattern hp, mk_pattern cp) in
  Tac2match.match_goal env sigma concl ~rev r >>= fun (hyps, ctx, subst) ->
    let of_ctxopt ctx = Value.of_ext val_matching_context (Option.default empty_context ctx) in
    let hids = Value.of_array Value.of_ident (Array.map_of_list fst hyps) in
    let hctx = Value.of_array of_ctxopt (Array.map_of_list snd hyps) in
    let subs = Value.of_array Value.of_constr (Array.map_of_list snd (Id.Map.bindings subst)) in
    let cctx = of_ctxopt ctx in
    let ans = Value.of_tuple [| hids; hctx; subs; cctx |] in
    Proofview.tclUNIT ans
  end
end

let () = define2 "pattern_instantiate" (repr_ext val_matching_context) constr begin fun ctx c ->
  let ans = Constr_matching.instantiate_context ctx c in
  return (Value.of_constr ans)
end

(** Error *)

let () = define1 "throw" exn begin fun (e, info) ->
  throw ~info e
end

(** Control *)

(** exn -> 'a *)
let () = define1 "zero" exn begin fun (e, info) ->
  fail ~info e
end

(** (unit -> 'a) -> (exn -> 'a) -> 'a *)
let () = define2 "plus" closure closure begin fun x k ->
  Proofview.tclOR (thaw x) (fun e -> Tac2ffi.apply k [Value.of_exn e])
end

(** (unit -> 'a) -> 'a *)
let () = define1 "once" closure begin fun f ->
  Proofview.tclONCE (thaw f)
end

(** (unit -> unit) list -> unit *)
let () = define1 "dispatch" (list closure) begin fun l ->
  let l = List.map (fun f -> Proofview.tclIGNORE (thaw f)) l in
  Proofview.tclDISPATCH l >>= fun () -> return v_unit
end

(** (unit -> unit) list -> (unit -> unit) -> (unit -> unit) list -> unit *)
let () = define3 "extend" (list closure) closure (list closure) begin fun lft tac rgt ->
  let lft = List.map (fun f -> Proofview.tclIGNORE (thaw f)) lft in
  let tac = Proofview.tclIGNORE (thaw tac) in
  let rgt = List.map (fun f -> Proofview.tclIGNORE (thaw f)) rgt in
  Proofview.tclEXTEND lft tac rgt >>= fun () -> return v_unit
end

(** (unit -> unit) -> unit *)
let () = define1 "enter" closure begin fun f ->
  let f = Proofview.tclIGNORE (thaw f) in
  Proofview.tclINDEPENDENT f >>= fun () -> return v_unit
end

(** (unit -> 'a) -> ('a * ('exn -> 'a)) result *)
let () = define1 "case" closure begin fun f ->
  Proofview.tclCASE (thaw f) >>= begin function
  | Proofview.Next (x, k) ->
    let k = Tac2ffi.mk_closure arity_one begin fun e ->
      let (e, info) = Value.to_exn e in
      set_bt info >>= fun info ->
      k (e, info)
    end in
    return (v_blk 0 [| Value.of_tuple [| x; Value.of_closure k |] |])
  | Proofview.Fail e -> return (v_blk 1 [| Value.of_exn e |])
  end
end

(** int -> int -> (unit -> 'a) -> 'a *)
let () = define3 "focus" int int closure begin fun i j tac ->
  Proofview.tclFOCUS i j (thaw tac)
end

(** unit -> unit *)
let () = define0 "shelve" begin
  Proofview.shelve >>= fun () -> return v_unit
end

(** unit -> unit *)
let () = define0 "shelve_unifiable" begin
  Proofview.shelve_unifiable >>= fun () -> return v_unit
end

let () = define1 "new_goal" evar begin fun ev ->
  Proofview.tclEVARMAP >>= fun sigma ->
  if Evd.mem sigma ev then
    Proofview.Unsafe.tclNEWGOALS [Proofview.with_empty_state ev] <*> Proofview.tclUNIT v_unit
  else throw err_notfound
end

(** unit -> constr *)
let () = define0 "goal" begin
  assert_focussed >>= fun () ->
  Proofview.Goal.enter_one begin fun gl ->
    let concl = Tacmach.pf_nf_concl gl in
    return (Value.of_constr concl)
  end
end

(** ident -> constr *)
let () = define1 "hyp" ident begin fun id ->
  pf_apply begin fun env _ ->
    let mem = try ignore (Environ.lookup_named id env); true with Not_found -> false in
    if mem then return (Value.of_constr (EConstr.mkVar id))
    else Tacticals.tclZEROMSG
      (str "Hypothesis " ++ quote (Id.print id) ++ str " not found") (* FIXME: Do something more sensible *)
  end
end

let () = define0 "hyps" begin
  pf_apply begin fun env _ ->
    let open Context in
    let open Named.Declaration in
    let hyps = List.rev (Environ.named_context env) in
    let map = function
    | LocalAssum (id, t) ->
      let t = EConstr.of_constr t in
      Value.of_tuple [|Value.of_ident id.binder_name; Value.of_option Value.of_constr None; Value.of_constr t|]
    | LocalDef (id, c, t) ->
      let c = EConstr.of_constr c in
      let t = EConstr.of_constr t in
      Value.of_tuple [|Value.of_ident id.binder_name; Value.of_option Value.of_constr (Some c); Value.of_constr t|]
    in
    return (Value.of_list map hyps)
  end
end

(** (unit -> constr) -> unit *)
let () = define1 "refine" closure begin fun c ->
  let c = thaw c >>= fun c -> Proofview.tclUNIT ((), Value.to_constr c) in
  Proofview.Goal.enter begin fun gl ->
    Refine.generic_refine ~typecheck:true c gl
  end >>= fun () -> return v_unit
end

let () = define2 "with_holes" closure closure begin fun x f ->
  Proofview.tclEVARMAP >>= fun sigma0 ->
  thaw x >>= fun ans ->
  Proofview.tclEVARMAP >>= fun sigma ->
  Proofview.Unsafe.tclEVARS sigma0 >>= fun () ->
  Tacticals.tclWITHHOLES false (Tac2ffi.apply f [ans]) sigma
end

let () = define1 "progress" closure begin fun f ->
  Proofview.tclPROGRESS (thaw f)
end

let () = define2 "abstract" (option ident) closure begin fun id f ->
  Abstract.tclABSTRACT id (Proofview.tclIGNORE (thaw f)) >>= fun () ->
  return v_unit
end

let () = define2 "time" (option string) closure begin fun s f ->
  let s = Option.map Bytes.to_string s in
  Proofview.tclTIME s (thaw f)
end

let () = define0 "check_interrupt" begin
  Proofview.tclCHECKINTERRUPT >>= fun () -> return v_unit
end

(** Fresh *)

let () = define2 "fresh_free_union" (repr_ext val_free) (repr_ext val_free) begin fun set1 set2 ->
  let ans = Id.Set.union set1 set2 in
  return (Value.of_ext Value.val_free ans)
end

let () = define1 "fresh_free_of_ids" (list ident) begin fun ids ->
  let free = List.fold_right Id.Set.add ids Id.Set.empty in
  return (Value.of_ext Value.val_free free)
end

let () = define1 "fresh_free_of_constr" constr begin fun c ->
  Proofview.tclEVARMAP >>= fun sigma ->
  let rec fold accu c = match EConstr.kind sigma c with
  | Constr.Var id -> Id.Set.add id accu
  | _ -> EConstr.fold sigma fold accu c
  in
  let ans = fold Id.Set.empty c in
  return (Value.of_ext Value.val_free ans)
end

let () = define2 "fresh_fresh" (repr_ext val_free) ident begin fun avoid id ->
  let nid = Namegen.next_ident_away_from id (fun id -> Id.Set.mem id avoid) in
  return (Value.of_ident nid)
end

(** Env *)

let () = define1 "env_get" (list ident) begin fun ids ->
  let r = match ids with
  | [] -> None
  | _ :: _ as ids ->
    let (id, path) = List.sep_last ids in
    let path = DirPath.make (List.rev path) in
    let fp = Libnames.make_path path id in
    try Some (Nametab.global_of_path fp) with Not_found -> None
  in
  return (Value.of_option Value.of_reference r)
end

let () = define1 "env_expand" (list ident) begin fun ids ->
  let r = match ids with
  | [] -> []
  | _ :: _ as ids ->
    let (id, path) = List.sep_last ids in
    let path = DirPath.make (List.rev path) in
    let qid = Libnames.make_qualid path id in
    Nametab.locate_all qid
  in
  return (Value.of_list Value.of_reference r)
end

let () = define1 "env_path" reference begin fun r ->
  match Nametab.path_of_global r with
  | fp ->
    let (path, id) = Libnames.repr_path fp in
    let path = DirPath.repr path in
    return (Value.of_list Value.of_ident (List.rev_append path [id]))
  | exception Not_found ->
    throw err_notfound
end

let () = define1 "env_instantiate" reference begin fun r ->
  Proofview.tclENV >>= fun env ->
  Proofview.tclEVARMAP >>= fun sigma ->
  let (sigma, c) = Evd.fresh_global env sigma r in
  Proofview.Unsafe.tclEVARS sigma >>= fun () ->
  return (Value.of_constr c)
end

(** Ind *)

let () = define2 "ind_equal" (repr_ext val_inductive) (repr_ext val_inductive) begin fun ind1 ind2 ->
  return (Value.of_bool (Ind.UserOrd.equal ind1 ind2))
end

let () = define1 "ind_data" (repr_ext val_inductive) begin fun ind ->
  Proofview.tclENV >>= fun env ->
  if Environ.mem_mind (fst ind) env then
    let mib = Environ.lookup_mind (fst ind) env in
    return (Value.of_ext val_ind_data (ind, mib))
  else
    throw err_notfound
end

let () = define1 "ind_repr" (repr_ext val_ind_data) begin fun (ind, _) ->
  return (Value.of_ext val_inductive ind)
end

let () = define1 "ind_index" (repr_ext val_inductive) begin fun (ind, n) ->
  return (Value.of_int n)
end

let () = define1 "ind_nblocks" (repr_ext val_ind_data) begin fun (ind, mib) ->
  return (Value.of_int (Array.length mib.Declarations.mind_packets))
end

let () = define1 "ind_nconstructors" (repr_ext val_ind_data) begin fun ((_, n), mib) ->
  let open Declarations in
  return (Value.of_int (Array.length mib.mind_packets.(n).mind_consnames))
end

let () = define2 "ind_get_block" (repr_ext val_ind_data) int begin fun (ind, mib) n ->
  if 0 <= n && n < Array.length mib.Declarations.mind_packets then
    return (Value.of_ext val_ind_data ((fst ind, n), mib))
  else throw err_notfound
end

let () = define2 "ind_get_constructor" (repr_ext val_ind_data) int begin fun ((mind, n), mib) i ->
  let open Declarations in
  let ncons = Array.length mib.mind_packets.(n).mind_consnames in
  if 0 <= i && i < ncons then
    (* WARNING: In the ML API constructors are indexed from 1 for historical
       reasons, but Ltac2 uses 0-indexing instead. *)
    return (Value.of_ext val_constructor ((mind, n), i + 1))
  else throw err_notfound
end

(** Ltac1 in Ltac2 *)

let ltac1 = Tac2ffi.repr_ext Value.val_ltac1
let of_ltac1 v = Value.of_ext Value.val_ltac1 v

let () = define1 "ltac1_ref" (list ident) begin fun ids ->
  let open Ltac_plugin in
  let r = match ids with
  | [] -> raise Not_found
  | _ :: _ as ids ->
    let (id, path) = List.sep_last ids in
    let path = DirPath.make (List.rev path) in
    let fp = Libnames.make_path path id in
    if Tacenv.exists_tactic fp then
      List.hd (Tacenv.locate_extended_all_tactic (Libnames.qualid_of_path fp))
    else raise Not_found
  in
  let tac = Tacinterp.Value.of_closure (Tacinterp.default_ist ()) (Tacenv.interp_ltac r) in
  return (Value.of_ext val_ltac1 tac)
end

let () = define1 "ltac1_run" ltac1 begin fun v ->
  let open Ltac_plugin in
  Tacinterp.tactic_of_value (Tacinterp.default_ist ()) v >>= fun () ->
  return v_unit
end

let () = define3 "ltac1_apply" ltac1 (list ltac1) closure begin fun f args k ->
  let open Ltac_plugin in
  let open Tacexpr in
  let open Locus in
  let k ret =
    Proofview.tclIGNORE (Tac2ffi.apply k [Value.of_ext val_ltac1 ret])
  in
  let fold arg (i, vars, lfun) =
    let id = Id.of_string ("x" ^ string_of_int i) in
    let x = Reference (ArgVar CAst.(make id)) in
    (succ i, x :: vars, Id.Map.add id arg lfun)
  in
  let (_, args, lfun) = List.fold_right fold args (0, [], Id.Map.empty) in
  let lfun = Id.Map.add (Id.of_string "F") f lfun in
  let ist = { (Tacinterp.default_ist ()) with Tacinterp.lfun = lfun; } in
  let tac = CAst.make @@ TacArg (TacCall (CAst.make (ArgVar CAst.(make @@ Id.of_string "F"),args))) in
  Tacinterp.val_interp ist tac k >>= fun () ->
  return v_unit
end

let () = define1 "ltac1_of_constr" constr begin fun c ->
  let open Ltac_plugin in
  return (Value.of_ext val_ltac1 (Tacinterp.Value.of_constr c))
end

let () = define1 "ltac1_to_constr" ltac1 begin fun v ->
  let open Ltac_plugin in
  return (Value.of_option Value.of_constr (Tacinterp.Value.to_constr v))
end

let () = define1 "ltac1_of_ident" ident begin fun c ->
  let open Ltac_plugin in
  return (Value.of_ext val_ltac1 (Taccoerce.Value.of_ident c))
end

let () = define1 "ltac1_to_ident" ltac1 begin fun v ->
  let open Ltac_plugin in
  return (Value.of_option Value.of_ident (Taccoerce.Value.to_ident v))
end

let () = define1 "ltac1_of_list" (list ltac1) begin fun l ->
  let open Geninterp.Val in
  return (Value.of_ext val_ltac1 (inject (Base typ_list) l))
end

let () = define1 "ltac1_to_list" ltac1 begin fun v ->
  let open Ltac_plugin in
  return (Value.of_option (Value.of_list of_ltac1) (Tacinterp.Value.to_list v))
end

(** ML types *)

(** Embed all Ltac2 data into Values *)
let to_lvar ist =
  let open Glob_ops in
  let lfun = Tac2interp.set_env ist Id.Map.empty in
  { empty_lvar with Ltac_pretype.ltac_genargs = lfun }

let gtypref kn = GTypRef (Other kn, [])

let intern_constr self ist c =
  let (_, (c, _)) = Genintern.intern Stdarg.wit_constr ist c in
  (GlbVal c, gtypref t_constr)

let interp_constr flags ist c =
  let open Pretyping in
  let ist = to_lvar ist in
  pf_apply ~catch_exceptions:true begin fun env sigma ->
    let (sigma, c) = understand_ltac flags env sigma ist WithoutTypeConstraint c in
    let c = Value.of_constr c in
    Proofview.Unsafe.tclEVARS sigma >>= fun () ->
    Proofview.tclUNIT c
  end

let () =
  let intern = intern_constr in
  let interp ist c = interp_constr constr_flags ist c in
  let print env sigma c = str "constr:(" ++ Printer.pr_lglob_constr_env env sigma c ++ str ")" in
  let subst subst c = Detyping.subst_glob_constr (Global.env()) subst c in
  let obj = {
    ml_intern = intern;
    ml_subst = subst;
    ml_interp = interp;
    ml_print = print;
  } in
  define_ml_object Tac2quote.wit_constr obj

let () =
  let intern = intern_constr in
  let interp ist c = interp_constr open_constr_no_classes_flags ist c in
  let print env sigma c = str "open_constr:(" ++ Printer.pr_lglob_constr_env env sigma c ++ str ")" in
  let subst subst c = Detyping.subst_glob_constr (Global.env()) subst c in
  let obj = {
    ml_intern = intern;
    ml_subst = subst;
    ml_interp = interp;
    ml_print = print;
  } in
  define_ml_object Tac2quote.wit_open_constr obj

let () =
  let interp _ id = return (Value.of_ident id) in
  let print _ _ id = str "ident:(" ++ Id.print id ++ str ")" in
  let obj = {
    ml_intern = (fun _ _ id -> GlbVal id, gtypref t_ident);
    ml_interp = interp;
    ml_subst = (fun _ id -> id);
    ml_print = print;
  } in
  define_ml_object Tac2quote.wit_ident obj

let () =
  let intern self ist c =
    let env = ist.Genintern.genv in
    let sigma = Evd.from_env env in
    let warn = if !Ltac_plugin.Tacintern.strict_check then fun x -> x else Constrintern.for_grammar in
    let _, pat = warn (fun () ->Constrintern.intern_constr_pattern env sigma ~as_type:false c) () in
    GlbVal pat, gtypref t_pattern
  in
  let subst subst c =
    let env = Global.env () in
    let sigma = Evd.from_env env in
    Patternops.subst_pattern env sigma subst c
  in
  let print env sigma pat = str "pat:(" ++ Printer.pr_lconstr_pattern_env env sigma pat ++ str ")" in
  let interp _ c = return (Value.of_pattern c) in
  let obj = {
    ml_intern = intern;
    ml_interp = interp;
    ml_subst = subst;
    ml_print = print;
  } in
  define_ml_object Tac2quote.wit_pattern obj

let () =
  let interp _ c =
    let open Ltac_pretype in
    let closure = {
      idents = Id.Map.empty;
      typed = Id.Map.empty;
      untyped = Id.Map.empty;
      genargs = Id.Map.empty;
    } in
    let c = { closure; term = c } in
    return (Value.of_ext val_preterm c)
  in
  let subst subst c = Detyping.subst_glob_constr (Global.env()) subst c in
  let print env sigma c = str "preterm:(" ++ Printer.pr_lglob_constr_env env sigma c ++ str ")" in
  let obj = {
    ml_intern = (fun _ _ e -> Empty.abort e);
    ml_interp = interp;
    ml_subst = subst;
    ml_print = print;
  } in
  define_ml_object Tac2quote.wit_preterm obj

let () =
  let intern self ist ref = match ref.CAst.v with
  | Tac2qexpr.QHypothesis id ->
    GlbVal (GlobRef.VarRef id), gtypref t_reference
  | Tac2qexpr.QReference qid ->
    let gr =
      try Nametab.locate qid
      with Not_found as exn ->
        let _, info = Exninfo.capture exn in
        Nametab.error_global_not_found ~info qid
    in
    GlbVal gr, gtypref t_reference
  in
  let subst s c = Globnames.subst_global_reference s c in
  let interp _ gr = return (Value.of_reference gr) in
  let print _ _ = function
  | GlobRef.VarRef id -> str "reference:(" ++ str "&" ++ Id.print id ++ str ")"
  | r -> str "reference:(" ++ Printer.pr_global r ++ str ")"
  in
  let obj = {
    ml_intern = intern;
    ml_subst = subst;
    ml_interp = interp;
    ml_print = print;
  } in
  define_ml_object Tac2quote.wit_reference obj

let () =
  let intern self ist (ids, tac) =
    let map { CAst.v = id } = id in
    let ids = List.map map ids in
    (* Prevent inner calls to Ltac2 values *)
    let extra = Tac2intern.drop_ltac2_env ist.Genintern.extra in
    let ltacvars = List.fold_right Id.Set.add ids ist.Genintern.ltacvars in
    let ist = { ist with Genintern.extra; ltacvars } in
    let _, tac = Genintern.intern Ltac_plugin.Tacarg.wit_tactic ist tac in
    let fold ty _ = GTypArrow (gtypref t_ltac1, ty) in
    let ty = List.fold_left fold (gtypref t_unit) ids in
    GlbVal (ids, tac), ty
  in
  let interp _ (ids, tac) =
    let clos args =
      let add lfun id v =
        let v = Tac2ffi.to_ext val_ltac1 v in
        Id.Map.add id v lfun
      in
      let lfun = List.fold_left2 add Id.Map.empty ids args in
      let ist = { env_ist = Id.Map.empty } in
      let lfun = Tac2interp.set_env ist lfun in
      let ist = Ltac_plugin.Tacinterp.default_ist () in
      let ist = { ist with Geninterp.lfun = lfun } in
      let tac = (Ltac_plugin.Tacinterp.eval_tactic_ist ist tac : unit Proofview.tactic) in
      let wrap (e, info) = set_bt info >>= fun info -> Proofview.tclZERO ~info e in
      Proofview.tclOR tac wrap >>= fun () ->
      return v_unit
    in
    let len = List.length ids in
    if Int.equal len 0 then
      clos []
    else
      return (Tac2ffi.of_closure (Tac2ffi.abstract len clos))
  in
  let subst s (ids, tac) = (ids, Genintern.substitute Ltac_plugin.Tacarg.wit_tactic s tac) in
  let print env sigma (ids, tac) =
    let ids =
      if List.is_empty ids then mt ()
      else pr_sequence Id.print ids ++ spc () ++ str "|-" ++ spc ()
    in
    str "ltac1:(" ++ ids ++ Ltac_plugin.Pptactic.pr_glob_tactic env tac ++ str ")"
  in
  let obj = {
    ml_intern = intern;
    ml_subst = subst;
    ml_interp = interp;
    ml_print = print;
  } in
  define_ml_object Tac2quote.wit_ltac1 obj

let () =
  let open Ltac_plugin in
  let intern self ist (ids, tac) =
    let map { CAst.v = id } = id in
    let ids = List.map map ids in
    (* Prevent inner calls to Ltac2 values *)
    let extra = Tac2intern.drop_ltac2_env ist.Genintern.extra in
    let ltacvars = List.fold_right Id.Set.add ids ist.Genintern.ltacvars in
    let ist = { ist with Genintern.extra; ltacvars } in
    let _, tac = Genintern.intern Ltac_plugin.Tacarg.wit_tactic ist tac in
    let fold ty _ = GTypArrow (gtypref t_ltac1, ty) in
    let ty = List.fold_left fold (gtypref t_ltac1) ids in
    GlbVal (ids, tac), ty
  in
  let interp _ (ids, tac) =
    let clos args =
      let add lfun id v =
        let v = Tac2ffi.to_ext val_ltac1 v in
        Id.Map.add id v lfun
      in
      let lfun = List.fold_left2 add Id.Map.empty ids args in
      let ist = { env_ist = Id.Map.empty } in
      let lfun = Tac2interp.set_env ist lfun in
      let ist = Ltac_plugin.Tacinterp.default_ist () in
      let ist = { ist with Geninterp.lfun = lfun } in
      return (Value.of_ext val_ltac1 (Tacinterp.Value.of_closure ist tac))
    in
    let len = List.length ids in
    if Int.equal len 0 then
      clos []
    else
      return (Tac2ffi.of_closure (Tac2ffi.abstract len clos))
  in
  let subst s (ids, tac) = (ids, Genintern.substitute Tacarg.wit_tactic s tac) in
  let print env sigma (ids, tac) =
    let ids =
      if List.is_empty ids then mt ()
      else pr_sequence Id.print ids ++ str " |- "
    in
    str "ltac1val:(" ++ ids++ Ltac_plugin.Pptactic.pr_glob_tactic env tac ++ str ")"
  in
  let obj = {
    ml_intern = intern;
    ml_subst = subst;
    ml_interp = interp;
    ml_print = print;
  } in
  define_ml_object Tac2quote.wit_ltac1val obj

(** Ltac2 in terms *)

let () =
  let interp ?loc ~poly env sigma tycon (ids, tac) =
    (* Syntax prevents bound notation variables in constr quotations *)
    let () = assert (Id.Set.is_empty ids) in
    let ist = Tac2interp.get_env @@ GlobEnv.lfun env in
    let tac = Proofview.tclIGNORE (Tac2interp.interp ist tac) in
    let name, poly = Id.of_string "ltac2", poly in
    let sigma, concl = match tycon with
    | Some ty -> sigma, ty
    | None -> GlobEnv.new_type_evar env sigma ~src:(loc,Evar_kinds.InternalHole)
    in
    let c, sigma = Proof.refine_by_tactic ~name ~poly (GlobEnv.renamed_env env) sigma concl tac in
    let j = { Environ.uj_val = EConstr.of_constr c; Environ.uj_type = concl } in
    (j, sigma)
  in
  GlobEnv.register_constr_interp0 wit_ltac2_constr interp

let () =
  let interp ?loc ~poly env sigma tycon id =
    let ist = Tac2interp.get_env @@ GlobEnv.lfun env in
    let env = GlobEnv.renamed_env env in
    let c = Id.Map.find id ist.env_ist in
    let c = Value.to_constr c in
    let t = Retyping.get_type_of env sigma c in
    let j = { Environ.uj_val = c; uj_type = t } in
    match tycon with
    | None ->
      j, sigma
    | Some ty ->
      let sigma =
        try Evarconv.unify_leq_delay env sigma t ty
        with Evarconv.UnableToUnify (sigma,e) ->
          Pretype_errors.error_actual_type ?loc env sigma j ty e
      in
      {j with Environ.uj_type = ty}, sigma
  in
  GlobEnv.register_constr_interp0 wit_ltac2_quotation interp

let () =
  let pr_raw id = Genprint.PrinterBasic (fun _env _sigma -> mt ()) in
  let pr_glb id = Genprint.PrinterBasic (fun _env _sigma -> str "$" ++ Id.print id) in
  let pr_top _ = Genprint.TopPrinterBasic mt in
  Genprint.register_print0 wit_ltac2_quotation pr_raw pr_glb pr_top

let () =
  let subs globs (ids, tac) =
    (* Let-bind the notation terms inside the tactic *)
    let fold id (c, _) (rem, accu) =
      let c = GTacExt (Tac2quote.wit_preterm, c) in
      let rem = Id.Set.remove id rem in
      rem, (Name id, c) :: accu
    in
    let rem, bnd = Id.Map.fold fold globs (ids, []) in
    let () = if not @@ Id.Set.is_empty rem then
      (* FIXME: provide a reasonable middle-ground with the behaviour
          introduced by 8d9b66b. We should be able to pass mere syntax to
          term notation without facing the wrath of the internalization. *)
      let plural = if Id.Set.cardinal rem <= 1 then " " else "s " in
      CErrors.user_err (str "Missing notation term for variable" ++ str plural ++
        pr_sequence Id.print (Id.Set.elements rem) ++
          str ", probably an ill-typed expression")
    in
    let tac = if List.is_empty bnd then tac else GTacLet (false, bnd, tac) in
    (Id.Set.empty, tac)
  in
  Genintern.register_ntn_subst0 wit_ltac2_constr subs

(** Ltac2 in Ltac1 *)

let () =
  let e = Tac2entries.Pltac.tac2expr_in_env in
  let inject (loc, v) = Ltac_plugin.Tacexpr.TacGeneric (Some "ltac2", in_gen (rawwit wit_ltac2) v) in
  Ltac_plugin.Tacentries.create_ltac_quotation "ltac2" inject (e, None)

(* Ltac1 runtime representation of Ltac2 closures. *)
let typ_ltac2 : valexpr Geninterp.Val.typ =
  Geninterp.Val.create "ltac2:ltac2_eval"

let cast_typ (type a) (tag : a Geninterp.Val.typ) (v : Geninterp.Val.t) : a =
  let Geninterp.Val.Dyn (tag', v) = v in
  match Geninterp.Val.eq tag tag' with
  | None -> assert false
  | Some Refl -> v

let () =
  let open Ltac_plugin in
  (* This is a hack similar to Tacentries.ml_val_tactic_extend *)
  let intern_fun _ e = Empty.abort e in
  let subst_fun s v = v in
  let () = Genintern.register_intern0 wit_ltac2_val intern_fun in
  let () = Genintern.register_subst0 wit_ltac2_val subst_fun in
  (* These are bound names and not relevant *)
  let tac_id = Id.of_string "F" in
  let arg_id = Id.of_string "X" in
  let interp_fun ist () =
    let tac = cast_typ typ_ltac2 @@ Id.Map.get tac_id ist.Tacinterp.lfun in
    let arg = Id.Map.get arg_id ist.Tacinterp.lfun in
    let tac = Tac2ffi.to_closure tac in
    Tac2ffi.apply tac [of_ltac1 arg] >>= fun ans ->
    let ans = Tac2ffi.to_ext val_ltac1 ans in
    Ftactic.return ans
  in
  let () = Geninterp.register_interp0 wit_ltac2_val interp_fun in
  define1 "ltac1_lambda" valexpr begin fun f ->
    let body = Tacexpr.TacGeneric (Some "coq-core.plugins.ltac2", in_gen (glbwit wit_ltac2_val) ()) in
    let clos = CAst.make (Tacexpr.TacFun ([Name arg_id], CAst.make (Tacexpr.TacArg body))) in
    let f = Geninterp.Val.inject (Geninterp.Val.Base typ_ltac2) f in
    let lfun = Id.Map.singleton tac_id f in
    let ist = { (Tacinterp.default_ist ()) with Tacinterp.lfun } in
    Proofview.tclUNIT (of_ltac1 (Tacinterp.Value.of_closure ist clos))
  end

let ltac2_eval =
  let open Ltac_plugin in
  let ml_name = {
    Tacexpr.mltac_plugin = "coq-core.plugins.ltac2";
    mltac_tactic = "ltac2_eval";
  } in
  let eval_fun args ist = match args with
  | [] -> assert false
  | tac :: args ->
    (* By convention the first argument is the tactic being applied, the rest
      being the arguments it should be fed with *)
    let tac = cast_typ typ_ltac2 tac in
    let tac = Tac2ffi.to_closure tac in
    let args = List.map (fun arg -> Tac2ffi.of_ext val_ltac1 arg) args in
    Proofview.tclIGNORE (Tac2ffi.apply tac args)
  in
  let () = Tacenv.register_ml_tactic ml_name [|eval_fun|] in
  { Tacexpr.mltac_name = ml_name; mltac_index = 0 }

let () =
  let open Ltac_plugin in
  let open Tacinterp in
  let interp ist (ids, tac) = match ids with
  | [] ->
    (* Evaluate the Ltac2 quotation eagerly *)
    let idtac = Value.of_closure { ist with lfun = Id.Map.empty }
        (CAst.make (Tacexpr.TacId [])) in
    let ist = { env_ist = Id.Map.empty } in
    Tac2interp.interp ist tac >>= fun _ ->
    Ftactic.return idtac
  | _ :: _ ->
    (* Return a closure [@f := {blob} |- fun ids => ltac2_eval(f, ids) ] *)
    (* This name cannot clash with Ltac2 variables which are all lowercase *)
    let self_id = Id.of_string "F" in
    let nas = List.map (fun id -> Name id) ids in
    let mk_arg id = Tacexpr.Reference (Locus.ArgVar (CAst.make id)) in
    let args = List.map mk_arg ids in
    let clos = CAst.make (Tacexpr.TacFun
        (nas, CAst.make (Tacexpr.TacML (ltac2_eval, mk_arg self_id :: args)))) in
    let self = GTacFun (List.map (fun id -> Name id) ids, tac) in
    let self = Tac2interp.interp_value { env_ist = Id.Map.empty } self in
    let self = Geninterp.Val.inject (Geninterp.Val.Base typ_ltac2) self in
    let ist = { ist with lfun = Id.Map.singleton self_id self } in
    Ftactic.return (Value.of_closure ist clos)
  in
  Geninterp.register_interp0 wit_ltac2 interp

let () =
  let pr_raw _ = Genprint.PrinterBasic (fun _env _sigma -> mt ()) in
  let pr_glb (ids, e) =
    let ids =
      if List.is_empty ids then mt ()
      else pr_sequence Id.print ids ++ str " |- "
    in
    Genprint.PrinterBasic Pp.(fun _env _sigma -> ids ++ Tac2print.pr_glbexpr e)
  in
  let pr_top _ = Genprint.TopPrinterBasic mt in
  Genprint.register_print0 wit_ltac2 pr_raw pr_glb pr_top

(** Built-in notation scopes *)

let add_scope s f =
  Tac2entries.register_scope (Id.of_string s) f

let rec pr_scope = let open CAst in function
| SexprStr {v=s} -> qstring s
| SexprInt {v=n} -> Pp.int n
| SexprRec (_, {v=na}, args) ->
  let na = match na with
  | None -> str "_"
  | Some id -> Id.print id
  in
  na ++ str "(" ++ prlist_with_sep (fun () -> str ", ") pr_scope args ++ str ")"

let scope_fail s args =
  let args = str "(" ++ prlist_with_sep (fun () -> str ", ") pr_scope args ++ str ")" in
  CErrors.user_err (str "Invalid arguments " ++ args ++ str " in scope " ++ str s)

let q_unit = CAst.make @@ CTacCst (AbsKn (Tuple 0))

let add_generic_scope s entry arg =
  let parse = function
  | [] ->
    let scope = Pcoq.Symbol.nterm entry in
    let act x = CAst.make @@ CTacExt (arg, x) in
    Tac2entries.ScopeRule (scope, act)
  | arg -> scope_fail s arg
  in
  add_scope s parse

open CAst

let () = add_scope "keyword" begin function
| [SexprStr {loc;v=s}] ->
  let scope = Pcoq.Symbol.token (Tok.PKEYWORD s) in
  Tac2entries.ScopeRule (scope, (fun _ -> q_unit))
| arg -> scope_fail "keyword" arg
end

let () = add_scope "terminal" begin function
| [SexprStr {loc;v=s}] ->
  let scope = Pcoq.Symbol.token (CLexer.terminal s) in
  Tac2entries.ScopeRule (scope, (fun _ -> q_unit))
| arg -> scope_fail "terminal" arg
end

let () = add_scope "list0" begin function
| [tok] ->
  let Tac2entries.ScopeRule (scope, act) = Tac2entries.parse_scope tok in
  let scope = Pcoq.Symbol.list0 scope in
  let act l = Tac2quote.of_list act l in
  Tac2entries.ScopeRule (scope, act)
| [tok; SexprStr {v=str}] ->
  let Tac2entries.ScopeRule (scope, act) = Tac2entries.parse_scope tok in
  let sep = Pcoq.Symbol.tokens [Pcoq.TPattern (CLexer.terminal str)] in
  let scope = Pcoq.Symbol.list0sep scope sep false in
  let act l = Tac2quote.of_list act l in
  Tac2entries.ScopeRule (scope, act)
| arg -> scope_fail "list0" arg
end

let () = add_scope "list1" begin function
| [tok] ->
  let Tac2entries.ScopeRule (scope, act) = Tac2entries.parse_scope tok in
  let scope = Pcoq.Symbol.list1 scope in
  let act l = Tac2quote.of_list act l in
  Tac2entries.ScopeRule (scope, act)
| [tok; SexprStr {v=str}] ->
  let Tac2entries.ScopeRule (scope, act) = Tac2entries.parse_scope tok in
  let sep = Pcoq.Symbol.tokens [Pcoq.TPattern (CLexer.terminal str)] in
  let scope = Pcoq.Symbol.list1sep scope sep false in
  let act l = Tac2quote.of_list act l in
  Tac2entries.ScopeRule (scope, act)
| arg -> scope_fail "list1" arg
end

let () = add_scope "opt" begin function
| [tok] ->
  let Tac2entries.ScopeRule (scope, act) = Tac2entries.parse_scope tok in
  let scope = Pcoq.Symbol.opt scope in
  let act opt = match opt with
  | None ->
    CAst.make @@ CTacCst (AbsKn (Other Core.c_none))
  | Some x ->
    CAst.make @@ CTacApp (CAst.make @@ CTacCst (AbsKn (Other Core.c_some)), [act x])
  in
  Tac2entries.ScopeRule (scope, act)
| arg -> scope_fail "opt" arg
end

let () = add_scope "self" begin function
| [] ->
  let scope = Pcoq.Symbol.self in
  let act tac = tac in
  Tac2entries.ScopeRule (scope, act)
| arg -> scope_fail "self" arg
end

let () = add_scope "next" begin function
| [] ->
  let scope = Pcoq.Symbol.next in
  let act tac = tac in
  Tac2entries.ScopeRule (scope, act)
| arg -> scope_fail "next" arg
end

let () = add_scope "tactic" begin function
| [] ->
  (* Default to level 5 parsing *)
  let scope = Pcoq.Symbol.nterml ltac2_expr "5" in
  let act tac = tac in
  Tac2entries.ScopeRule (scope, act)
| [SexprInt {loc;v=n}] as arg ->
  let () = if n < 0 || n > 6 then scope_fail "tactic" arg in
  let scope = Pcoq.Symbol.nterml ltac2_expr (string_of_int n) in
  let act tac = tac in
  Tac2entries.ScopeRule (scope, act)
| arg -> scope_fail "tactic" arg
end

let () = add_scope "thunk" begin function
| [tok] ->
  let Tac2entries.ScopeRule (scope, act) = Tac2entries.parse_scope tok in
  let act e = Tac2quote.thunk (act e) in
  Tac2entries.ScopeRule (scope, act)
| arg -> scope_fail "thunk" arg
end

let () = add_scope "constr" (fun arg ->
    let delimiters = List.map (function
        | SexprRec (_, { v = Some s }, []) -> s
        | _ -> scope_fail "constr" arg)
        arg
    in
    let act e = Tac2quote.of_constr ~delimiters e in
    Tac2entries.ScopeRule (Pcoq.Symbol.nterm Pcoq.Constr.constr, act)
  )

let () = add_scope "open_constr" (fun arg ->
    let delimiters = List.map (function
        | SexprRec (_, { v = Some s }, []) -> s
        | _ -> scope_fail "open_constr" arg)
        arg
    in
    let act e = Tac2quote.of_open_constr ~delimiters e in
    Tac2entries.ScopeRule (Pcoq.Symbol.nterm Pcoq.Constr.constr, act)
  )

let add_expr_scope name entry f =
  add_scope name begin function
  | [] -> Tac2entries.ScopeRule (Pcoq.Symbol.nterm entry, f)
  | arg -> scope_fail name arg
  end

let () = add_expr_scope "ident" q_ident (fun id -> Tac2quote.of_anti Tac2quote.of_ident id)
let () = add_expr_scope "bindings" q_bindings Tac2quote.of_bindings
let () = add_expr_scope "with_bindings" q_with_bindings Tac2quote.of_bindings
let () = add_expr_scope "intropattern" q_intropattern Tac2quote.of_intro_pattern
let () = add_expr_scope "intropatterns" q_intropatterns Tac2quote.of_intro_patterns
let () = add_expr_scope "destruction_arg" q_destruction_arg Tac2quote.of_destruction_arg
let () = add_expr_scope "induction_clause" q_induction_clause Tac2quote.of_induction_clause
let () = add_expr_scope "conversion" q_conversion Tac2quote.of_conversion
let () = add_expr_scope "rewriting" q_rewriting Tac2quote.of_rewriting
let () = add_expr_scope "clause" q_clause Tac2quote.of_clause
let () = add_expr_scope "hintdb" q_hintdb Tac2quote.of_hintdb
let () = add_expr_scope "occurrences" q_occurrences Tac2quote.of_occurrences
let () = add_expr_scope "dispatch" q_dispatch Tac2quote.of_dispatch
let () = add_expr_scope "strategy" q_strategy_flag Tac2quote.of_strategy_flag
let () = add_expr_scope "reference" q_reference Tac2quote.of_reference
let () = add_expr_scope "move_location" q_move_location Tac2quote.of_move_location
let () = add_expr_scope "pose" q_pose Tac2quote.of_pose
let () = add_expr_scope "assert" q_assert Tac2quote.of_assertion
let () = add_expr_scope "constr_matching" q_constr_matching Tac2quote.of_constr_matching
let () = add_expr_scope "goal_matching" q_goal_matching Tac2quote.of_goal_matching
let () = add_expr_scope "format" Pcoq.Prim.lstring Tac2quote.of_format

let () = add_generic_scope "pattern" Pcoq.Constr.constr Tac2quote.wit_pattern

(** seq scope, a bit hairy *)

open Pcoq

type _ converter =
| CvNil : (Loc.t -> raw_tacexpr) converter
| CvCns : 'act converter * ('a -> raw_tacexpr) option -> ('a -> 'act) converter

let rec apply : type a. a converter -> raw_tacexpr list -> a = function
| CvNil -> fun accu loc -> Tac2quote.of_tuple ~loc accu
| CvCns (c, None) -> fun accu x -> apply c accu
| CvCns (c, Some f) -> fun accu x -> apply c (f x :: accu)

type seqrule =
| Seqrule : (Tac2expr.raw_tacexpr, Gramlib.Grammar.norec, 'act, Loc.t -> raw_tacexpr) Rule.t * 'act converter -> seqrule

let rec make_seq_rule = function
| [] ->
  Seqrule (Pcoq.Rule.stop, CvNil)
| tok :: rem ->
  let Tac2entries.ScopeRule (scope, f) = Tac2entries.parse_scope tok in
  let scope =
    match Pcoq.generalize_symbol scope with
    | None ->
      CErrors.user_err (str "Recursive symbols (self / next) are not allowed in local rules")
    | Some scope -> scope
  in
  let Seqrule (r, c) = make_seq_rule rem in
  let r = Pcoq.Rule.next_norec r scope in
  let f = match tok with
  | SexprStr _ -> None (* Leave out mere strings *)
  | _ -> Some f
  in
  Seqrule (r, CvCns (c, f))

let () = add_scope "seq" begin fun toks ->
  let scope =
    let Seqrule (r, c) = make_seq_rule (List.rev toks) in
    Pcoq.(Symbol.rules [Rules.make r (apply c [])])
  in
  Tac2entries.ScopeRule (scope, (fun e -> e))
end
