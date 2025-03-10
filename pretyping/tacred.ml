(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open CErrors
open Util
open Names
open Constr
open Context
open Termops
open Environ
open EConstr
open CClosure
open Reductionops

module RelDecl = Context.Rel.Declaration
module NamedDecl = Context.Named.Declaration

(* Errors *)

type reduction_tactic_error =
    InvalidAbstraction of env * Evd.evar_map * EConstr.constr * (env * Type_errors.type_error)

exception ReductionTacticError of reduction_tactic_error

(* Evaluable reference *)

exception Elimconst
exception Redelimination

type evaluable_global_reference =
  | EvalVarRef of Id.t
  | EvalConstRef of Constant.t

(* Better to have it here that in closure, since used in grammar.cma *)
let eq_egr e1 e2 = match e1, e2 with
    EvalConstRef con1, EvalConstRef con2 -> Constant.CanOrd.equal con1 con2
  | EvalVarRef id1, EvalVarRef id2 -> Id.equal id1 id2
  | _, _ -> false

(* Here the semantics is completely unclear.
   What does "Hint Unfold t" means when "t" is a parameter?
   Does the user mean "Unfold X.t" or does she mean "Unfold y"
   where X.t is later on instantiated with y? I choose the first
   interpretation (i.e. an evaluable reference is never expanded). *)
let subst_evaluable_reference subst = function
  | EvalVarRef id -> EvalVarRef id
  | EvalConstRef kn -> EvalConstRef (Mod_subst.subst_constant subst kn)

let error_not_evaluable r =
  user_err
    Pp.(str "Cannot coerce" ++ spc () ++ Nametab.pr_global_env Id.Set.empty r ++
        spc () ++ str "to an evaluable reference.")

let is_evaluable_const env cst =
  is_transparent env (ConstKey cst) && evaluable_constant cst env

let is_evaluable_var env id =
  is_transparent env (VarKey id) && evaluable_named id env

let is_evaluable env = function
  | EvalConstRef cst -> is_evaluable_const env cst
  | EvalVarRef id -> is_evaluable_var env id

let value_of_evaluable_ref env evref u =
  match evref with
  | EvalConstRef con ->
    let u = Unsafe.to_instance u in
    EConstr.of_constr (constant_value_in env (con, u))
  | EvalVarRef id -> env |> lookup_named id |> NamedDecl.get_value |> Option.get

let evaluable_of_global_reference env = function
  | GlobRef.ConstRef cst when is_evaluable_const env cst -> EvalConstRef cst
  | GlobRef.VarRef id when is_evaluable_var env id -> EvalVarRef id
  | r -> error_not_evaluable r

let global_of_evaluable_reference = function
  | EvalConstRef cst -> GlobRef.ConstRef cst
  | EvalVarRef id -> GlobRef.VarRef id

type evaluable_reference =
  | EvalConst of Constant.t
  | EvalVar of Id.t
  | EvalRel of int
  | EvalEvar of EConstr.existential

let evaluable_reference_eq sigma r1 r2 = match r1, r2 with
| EvalConst c1, EvalConst c2 -> Constant.CanOrd.equal c1 c2
| EvalVar id1, EvalVar id2 -> Id.equal id1 id2
| EvalRel i1, EvalRel i2 -> Int.equal i1 i2
| EvalEvar (e1, ctx1), EvalEvar (e2, ctx2) ->
  EConstr.eq_constr sigma (mkEvar (e1, ctx1)) (mkEvar (e2, ctx2))
| _ -> false

let mkEvalRef ref u =
  match ref with
  | EvalConst cst -> mkConstU (cst,u)
  | EvalVar id -> mkVar id
  | EvalRel n -> mkRel n
  | EvalEvar ev -> EConstr.mkEvar ev

let isEvalRef env sigma c = match EConstr.kind sigma c with
  | Const (sp,_) -> is_evaluable env (EvalConstRef sp)
  | Var id -> is_evaluable env (EvalVarRef id)
  | Rel _ | Evar _ -> true
  | _ -> false

let destEvalRefU sigma c = match EConstr.kind sigma c with
  | Const (cst,u) ->  EvalConst cst, u
  | Var id  -> (EvalVar id, EInstance.empty)
  | Rel n -> (EvalRel n, EInstance.empty)
  | Evar ev -> (EvalEvar ev, EInstance.empty)
  | _ -> anomaly (Pp.str "Not an unfoldable reference.")

let unsafe_reference_opt_value env sigma eval =
  match eval with
  | EvalConst cst ->
    (match (lookup_constant cst env).Declarations.const_body with
    | Declarations.Def c -> Some (EConstr.of_constr c)
    | _ -> None)
  | EvalVar id ->
      env |> lookup_named id |> NamedDecl.get_value
  | EvalRel n ->
      env |> lookup_rel n |> RelDecl.get_value |> Option.map (Vars.lift n)
  | EvalEvar ev ->
    match EConstr.kind sigma (mkEvar ev) with
    | Evar _ -> None
    | c -> Some (EConstr.of_kind c)

let reference_opt_value env sigma eval u =
  match eval with
  | EvalConst cst ->
    let u = EInstance.kind sigma u in
    Option.map EConstr.of_constr (constant_opt_value_in env (cst,u))
  | EvalVar id ->
      env |> lookup_named id |> NamedDecl.get_value
  | EvalRel n ->
      env |> lookup_rel n |> RelDecl.get_value |> Option.map (Vars.lift n)
  | EvalEvar ev ->
    match EConstr.kind sigma (mkEvar ev) with
    | Evar _ -> None
    | c -> Some (EConstr.of_kind c)

exception NotEvaluable
let reference_value env sigma c u =
  match reference_opt_value env sigma c u with
    | None -> raise NotEvaluable
    | Some d -> d

let is_primitive_val sigma c = match EConstr.kind sigma c with
  | Int _ | Float _ | Array _ -> true
  | _ -> false

(************************************************************************)
(* Reduction of constants hiding a fixpoint (e.g. for "simpl" tactic).  *)
(* One reuses the name of the function after reduction of the fixpoint  *)

type constant_evaluation =
  | EliminationFix of int * int * (int * (int * constr) list * int)
  | EliminationMutualFix of
      int * evaluable_reference *
      ((int*evaluable_reference) option array *
       (int * (int * constr) list * int))
  | EliminationCases of int
  | EliminationProj of int
  | NotAnElimination

(* We use a cache registered as a global table *)

type frozen = constant_evaluation Cmap.t

let eval_table = Summary.ref (Cmap.empty : frozen) ~name:"evaluation"

(* [compute_consteval] determines whether c is an "elimination constant"

   either [yn:Tn]..[y1:T1](match yi with f1..fk end g1 ..gp)

   or     [yn:Tn]..[y1:T1](Fix(f|t) yi1..yip)
          with yi1..yip distinct variables among the yi, not occurring in t

   In the second case, [check_fix_reversibility [T1;...;Tn] args fix]
   checks that [args] is a subset of disjoint variables in y1..yn (a necessary
   condition for reversibility). It also returns the relevant
   information ([i1,Ti1;..;ip,Tip],n) in order to compute an
   equivalent of Fix(f|t) such that

   g := [xp:Tip']..[x1:Ti1'](f a1..an)
     == [xp:Tip']..[x1:Ti1'](Fix(f|t) yi1..yip)

   with a_k:=y_k if k<>i_j, a_k:=args_k otherwise, and
   Tij':=Tij[x1..xi(j-1) <- a1..ai(j-1)]

   Note that the types Tk, when no i_j=k, must not be dependent on
   the xp..x1.
*)

let check_fix_reversibility sigma labs args ((lv,i),(_,tys,bds)) =
  let n = List.length labs in
  let nargs = List.length args in
  if nargs > n then raise Elimconst;
  let nbfix = Array.length bds in
  let li =
    List.map
      (function d -> match EConstr.kind sigma d with
         | Rel k ->
             if
               Array.for_all (Vars.noccurn sigma k) tys
               && Array.for_all (Vars.noccurn sigma (k+nbfix)) bds
               && k <= n
             then
               (k, List.nth labs (k-1))
             else
               raise Elimconst
         | _ ->
             raise Elimconst) args
  in
  let reversible_rels = List.map fst li in
  if not (List.distinct_f Int.compare reversible_rels) then
    raise Elimconst;
  List.iteri (fun i t_i ->
    if not (Int.List.mem_assoc (i+1) li) then
      let fvs = List.map ((+) (i+1)) (Int.Set.elements (free_rels sigma t_i)) in
      match List.intersect Int.equal fvs reversible_rels with
      | [] -> ()
      | _ -> raise Elimconst)
    labs;
  let k = lv.(i) in
  if k < nargs then
(*  Such an optimisation would need eta-expansion
      let p = destRel (List.nth args k) in
      EliminationFix (n-p+1,(nbfix,li,n))
*)
    EliminationFix (n,nargs,(nbfix,li,n))
  else
    EliminationFix (n-nargs+k+1,nargs,(nbfix,li,n))

(* Heuristic to look if global names are associated to other
   components of a mutual fixpoint *)

let invert_name labs l {binder_name=na0} env sigma ref na =
  match na.binder_name with
  | Name id ->
      let minfxargs = List.length l in
      begin match na0 with
      | Name id' when Id.equal id' id ->
        Some (minfxargs,ref)
      | _ ->
        let refi = match ref with
          | EvalRel _ | EvalEvar _ -> None
          | EvalVar id' -> Some (EvalVar id)
          | EvalConst kn ->
            let kn = Constant.change_label kn (Label.of_id id) in
            if Environ.mem_constant kn env then Some (EvalConst kn) else None
        in
        match refi with
          | None -> None
          | Some ref ->
              try match unsafe_reference_opt_value env sigma ref with
                | None -> None
                | Some c ->
                    let labs',ccl = decompose_lam sigma c in
                    let _, l' = whd_betalet_stack env sigma ccl in
                    let labs' = List.map snd labs' in
                    (* ppedrot: there used to be generic equality on terms here *)
                    let eq_constr c1 c2 = EConstr.eq_constr sigma c1 c2 in
                    if List.equal eq_constr labs' labs &&
                       List.equal eq_constr l l' then Some (minfxargs,ref)
                    else None
              with Not_found (* Undefined ref *) -> None
      end
  | Anonymous -> None (* Actually, should not occur *)

(* [compute_consteval_direct] expand all constant in a whole, but
   [compute_consteval_mutual_fix] only one by one, until finding the
   last one before the Fix if the latter is mutually defined *)

let compute_consteval_direct env sigma ref =
  let rec srec env n labs onlyproj c =
    let c',l = whd_betadeltazeta_stack env sigma c in
    match EConstr.kind sigma c' with
      | Lambda (id,t,g) when List.is_empty l && not onlyproj ->
          let open Context.Rel.Declaration in
          srec (push_rel (LocalAssum (id,t)) env) (n+1) (t::labs) onlyproj g
      | Fix fix when not onlyproj ->
          (try check_fix_reversibility sigma labs l fix
          with Elimconst -> NotAnElimination)
      | Case (_,_,_,_,_,d,_) when isRel sigma d && not onlyproj -> EliminationCases n
      | Case (_,_,_,_,_,d,_) -> srec env n labs true d
      | Proj (p, d) when isRel sigma d -> EliminationProj n
      | _ -> NotAnElimination
  in
  match unsafe_reference_opt_value env sigma ref with
    | None -> NotAnElimination
    | Some c -> srec env 0 [] false c

let compute_consteval_mutual_fix env sigma ref =
  let rec srec env minarg labs ref c =
    let c',l = whd_betalet_stack env sigma c in
    let nargs = List.length l in
    match EConstr.kind sigma c' with
      | Lambda (na,t,g) when List.is_empty l ->
          let open Context.Rel.Declaration in
          srec (push_rel (LocalAssum (na,t)) env) (minarg+1) (t::labs) ref g
      | Fix ((lv,i),(names,_,_)) ->
          (* Last known constant wrapping Fix is ref = [labs](Fix l) *)
          (match compute_consteval_direct env sigma ref with
             | NotAnElimination -> (*Above const was eliminable but this not!*)
                 NotAnElimination
             | EliminationFix (minarg',minfxargs,infos) ->
                 let refs =
                   Array.map
                     (invert_name labs l names.(i) env sigma ref) names in
                 let new_minarg = max (minarg'+minarg-nargs) minarg' in
                 EliminationMutualFix (new_minarg,ref,(refs,infos))
             | _ -> assert false)
      | _ when isEvalRef env sigma c' ->
          (* Forget all \'s and args and do as if we had started with c' *)
          let ref,_ = destEvalRefU sigma c' in
          (match unsafe_reference_opt_value env sigma ref with
            | None -> anomaly (Pp.str "Should have been trapped by compute_direct.")
            | Some c -> srec env (minarg-nargs) [] ref c)
      | _ -> (* Should not occur *) NotAnElimination
  in
  match unsafe_reference_opt_value env sigma ref with
    | None -> (* Should not occur *) NotAnElimination
    | Some c -> srec env 0 [] ref c

let compute_consteval env sigma ref =
  match compute_consteval_direct env sigma ref with
    | EliminationFix (_,_,(nbfix,_,_)) when not (Int.equal nbfix 1) ->
        compute_consteval_mutual_fix env sigma ref
    | elim -> elim

let reference_eval env sigma = function
  | EvalConst cst as ref ->
      (try
         Cmap.find cst !eval_table
       with Not_found -> begin
         let v = compute_consteval env sigma ref in
         eval_table := Cmap.add cst v !eval_table;
         v
       end)
  | ref -> compute_consteval env sigma ref

(* If f is bound to EliminationFix (n',infos), then n' is the minimal
   number of args for starting the reduction and infos is
   (nbfix,[(yi1,Ti1);...;(yip,Tip)],n) indicating that f converts
   to some [y1:T1,...,yn:Tn](Fix(..) yip .. yi1) where the y_{i_j} consist in a
   disjoint subset of the yi, i.e. 1 <= ij <= n and the ij are disjoint (in
   particular, p <= n).

   f is applied to largs := arg1 .. argn and we need for recursive
   calls to build the function

      g := [xp:Tip',...,x1:Ti1'](f a1 ... an)

   s.t. (g u1 ... up) reduces to (Fix(..) u1 ... up)

   This is made possible by setting
      a_k:=x_j    if k=i_j for some j
      a_k:=arg_k  otherwise

   The type Tij' is Tij[yi(j-1)..y1 <- ai(j-1)..a1]
*)

let xname = Name Namegen.default_dependent_ident

(* [f] is convertible to [Fix(recindices,bodynum),bodyvect)]:
   do so that the reduction uses this extra information *)

let dummy = mkProp

(* Mark every occurrence of substituted vars (associated to a function)
   as a problem variable: an evar that can be instantiated either by
   vfx (expanded fixpoint) or vfun (named function). *)
let substl_with_function subst sigma constr =
  let evd = ref sigma in
  let minargs = ref Evar.Map.empty in
  let v = Array.of_list subst in
  let rec subst_total k c = match EConstr.kind sigma c with
  | Rel i when k < i ->
    if i <= k + Array.length v then
      match v.(i-k-1) with
      | (fx, Some (min, ref)) ->
        let sigma = !evd in
        let (sigma, evk) = Evarutil.new_pure_evar empty_named_context_val sigma dummy in
        evd := sigma;
        minargs := Evar.Map.add evk (min, fx, ref) !minargs;
        mkEvar (evk, SList.empty)
      | (fx, None) -> Vars.lift k fx
    else mkRel (i - Array.length v)
  | _ ->
    map_with_binders sigma succ subst_total k c in
  let c = subst_total 0 constr in
  (c, !evd, !minargs)

exception Partial

(* each problem variable that cannot be made totally applied even by
   reduction is solved by the expanded fix term. *)
let solve_arity_problem env sigma fxminargs c =
  let set = ref Evar.Set.empty in
  let set_fix i = set := Evar.Set.add i !set in
  let rec check strict c =
    let c' = whd_betaiotazeta env sigma c in
    let (h,rcargs) = decompose_app_vect sigma c' in
    match EConstr.kind sigma h with
        Evar(i,_) when Evar.Map.mem i fxminargs && not (Evar.Set.mem i !set) ->
          let minargs, _, _ = Evar.Map.find i fxminargs in
          if Array.length rcargs < minargs then
            if strict then set_fix i
            else raise Partial;
          Array.iter (check strict) rcargs
      | (Var _|Const _) when isEvalRef env sigma h ->
          (let ev, u = destEvalRefU sigma h in
             match reference_opt_value env sigma ev u with
             | Some h' ->
                let bak = !set in
                (try Array.iter (check false) rcargs
                with Partial ->
                  set := bak;
                  check strict (mkApp(h',rcargs)))
            | None -> Array.iter (check strict) rcargs)
      | _ -> EConstr.iter sigma (check strict) c' in
  check true c;
  !set

let substl_checking_arity env subst sigma c =
  (* we initialize the problem: *)
  let body,sigma,minargs = substl_with_function subst sigma c in
  (* we collect arity constraints *)
  let ans = solve_arity_problem env sigma minargs body in
  (* we propagate the constraints: solved problems are substituted;
     the other ones are replaced by the function symbol *)
  let rec nf_fix k c = match EConstr.kind sigma c with
  | Evar (i, SList.Nil) ->
    (* FIXME: find a less hackish way of doing this *)
    begin match Evar.Map.find i minargs with
    | (_, fx, ref) ->
      if Evar.Set.mem i ans then Vars.lift k fx
      else Vars.lift k ref
    | exception Not_found ->
      (* An argumentless evar that was not generated by substl_with_function *)
      c
    end
  | _ -> EConstr.map_with_binders sigma succ nf_fix k c
  in
  nf_fix 0 body

type fix_reduction_result = NotReducible | Reduced of (constr * constr list)

let contract_fix_use_function env sigma f
  ((recindices,bodynum),(_names,_types,bodies as typedbodies)) =
  let (names, (nbfix, lv, n)), u, largs = f in
  let lu = List.firstn n largs in
  let p = List.length lv in
  let lyi = List.map fst lv in
  let la =
    List.map_i (fun q aq ->
      (* k from the comment is q+1 *)
      try mkRel (p+1-(List.index Int.equal (n-q) lyi))
      with Not_found -> Vars.lift p aq)
      0 lu
  in
  let f i = match names.(i) with
  | None -> None
  | Some (minargs,ref) ->
      let body = applist (mkEvalRef ref u, la) in
      let g =
        List.fold_left_i (fun q (* j = n+1-q *) c (ij,tij) ->
          let subst = List.map (Vars.lift (-q)) (List.firstn (n-ij) la) in
          let tij' = Vars.substl (List.rev subst) tij in
          let x = make_annot xname Sorts.Relevant in  (* TODO relevance *)
          mkLambda (x,tij',c)) 1 body (List.rev lv)
      in Some (minargs,g)
  in
  let nbodies = Array.length recindices in
  let make_Fi j = (mkFix((recindices,j),typedbodies), f j) in
  let lbodies = List.init nbodies make_Fi in
  let c = substl_checking_arity env (List.rev lbodies) sigma (nf_beta env sigma bodies.(bodynum)) in
  nf_beta env sigma c

let contract_cofix_use_function env sigma f
  (bodynum,(names,_,bodies as typedbodies)) args =
  let f =
    if isConst sigma f then
      let minargs = List.length args in
      fun i ->
        if Int.equal i bodynum then Some (minargs, f)
        else match names.(i).binder_name with
          | Anonymous -> None
          | Name id ->
              (* In case of a call to another component of a block of
                  mutual inductive, try to reuse the global name if
                  the block was indeed initially built as a global
                  definition *)
              let (kn, u) = destConst sigma f in
              let kn = Constant.change_label kn (Label.of_id id) in
              let cst = (kn, EInstance.kind sigma u) in
              try match constant_opt_value_in env cst with
                | None -> None
                    (* TODO: check kn is correct *)
                | Some _ -> Some (minargs,mkConstU (kn, u))
              with Not_found -> None
    else
      fun _ -> None in
  let nbodies = Array.length bodies in
  let make_Fi j = (mkCoFix(j,typedbodies), f j) in
  let subbodies = List.init nbodies make_Fi in
  substl_checking_arity env (List.rev subbodies)
    sigma (nf_beta env sigma bodies.(bodynum))

type 'a miota_args = {
  mU      : EInstance.t; (* Universe instance of the return clause *)
  mParams : constr array; (* Parameters of the inductive *)
  mP      : case_return;     (* the result type *)
  mconstr : constr;     (** the constructor *)
  mci     : case_info;  (** special info to re-build pattern *)
  mcargs  : 'a list;    (** the constructor's arguments *)
  mlf     : 'a pcase_branch array }  (** the branch code vector *)

let reduce_mind_case env sigma mia =
  match EConstr.kind sigma mia.mconstr with
    | Construct ((_, i as cstr), u) ->
        let real_cargs = List.skipn mia.mci.ci_npar mia.mcargs in
        let br = mia.mlf.(i - 1) in
        let ctx = EConstr.expand_branch env sigma mia.mU mia.mParams cstr br in
        let br = it_mkLambda_or_LetIn (snd br) ctx in
        applist (br, real_cargs)
    | CoFix cofix ->
        let cofix_def = contract_cofix sigma cofix in
        (* XXX Is NoInvert OK here? *)
        mkCase (mia.mci, mia.mU, mia.mParams, mia.mP, NoInvert, applist(cofix_def,mia.mcargs), mia.mlf)
    | _ -> assert false

let reduce_mind_case_use_function f env sigma mia =
  match EConstr.kind sigma mia.mconstr with
    | Construct ((_, i as cstr),u) ->
        let real_cargs = List.skipn mia.mci.ci_npar mia.mcargs in
        let br = mia.mlf.(i - 1) in
        let ctx = EConstr.expand_branch env sigma mia.mU mia.mParams cstr br in
        let br = it_mkLambda_or_LetIn (snd br) ctx in
        applist (br, real_cargs)
    | CoFix (bodynum,(names,_,_) as cofix) ->
        let cofix_def =
          contract_cofix_use_function env sigma f cofix mia.mcargs in
        mkCase (mia.mci, mia.mU, mia.mParams, mia.mP, NoInvert, applist(cofix_def,mia.mcargs), mia.mlf)
    | _ -> assert false


let match_eval_ref env sigma constr stack =
  match EConstr.kind sigma constr with
  | Const (sp, u) ->
     reduction_effect_hook env sigma sp
        (lazy (EConstr.to_constr sigma (applist (constr,stack))));
     if is_evaluable env (EvalConstRef sp) then Some (EvalConst sp, u) else None
  | Var id when is_evaluable env (EvalVarRef id) -> Some (EvalVar id, EInstance.empty)
  | Rel i -> Some (EvalRel i, EInstance.empty)
  | Evar ev -> Some (EvalEvar ev, EInstance.empty)
  | _ -> None

let match_eval_ref_value env sigma constr stack =
  match EConstr.kind sigma constr with
  | Const (sp, u) ->
     reduction_effect_hook env sigma sp
        (lazy (EConstr.to_constr sigma (applist (constr,stack))));
    if is_evaluable env (EvalConstRef sp) then
      let u = EInstance.kind sigma u in
      Some (EConstr.of_constr (constant_value_in env (sp, u)))
    else
      None
  | Proj (p, c) when not (Projection.unfolded p) ->
     if is_evaluable env (EvalConstRef (Projection.constant p)) then
       Some (mkProj (Projection.unfold p, c))
     else None
  | Var id when is_evaluable env (EvalVarRef id) ->
     env |> lookup_named id |> NamedDecl.get_value
  | Rel n ->
     env |> lookup_rel n |> RelDecl.get_value |> Option.map (Vars.lift n)
  | _ -> None

let push_app sigma (hd, stk as p) = match EConstr.kind sigma hd with
| App (hd, args) ->
  (hd, Array.fold_right (fun x accu -> x :: accu) args stk)
| _ -> p

let recargs = function
  | EvalVar _ | EvalRel _ | EvalEvar _ -> None
  | EvalConst c -> ReductionBehaviour.get (GlobRef.ConstRef c)

let fix_recarg ((recindices,bodynum),_) stack =
  assert (0 <= bodynum && bodynum < Array.length recindices);
  let recargnum = Array.get recindices bodynum in
  try
    Some (recargnum, List.nth stack recargnum)
  with Failure _ ->
    None

let reduce_projection env sigma p ~npars (recarg'hd,stack') stack =
  (match EConstr.kind sigma recarg'hd with
  | Construct _ ->
    let proj_narg = npars + Projection.arg p in
    Reduced (List.nth stack' proj_narg, stack)
  | _ -> NotReducible)

let rec beta_applist sigma accu c stk = match EConstr.kind sigma c, stk with
| Lambda (_, _, c), arg :: stk -> beta_applist sigma (arg :: accu) c stk
| _ -> Vars.substl accu c, stk

let whd_nothing_for_iota env sigma s =
  let rec whrec (x, stack as s) =
    match EConstr.kind sigma x with
      | Rel n ->
          let open Context.Rel.Declaration in
          (match lookup_rel n env with
             | LocalDef (_,body,_) -> whrec (Vars.lift n body, stack)
             | _ -> s)
      | Var id ->
          let open Context.Named.Declaration in
          (match lookup_named id env with
             | LocalDef (_,body,_) -> whrec (body, stack)
             | _ -> s)
      | Evar ev -> s
      | Meta ev ->
        (try whrec (Evd.meta_value sigma ev, stack)
        with Not_found -> s)
      | Const (const, u) ->
          let u = EInstance.kind sigma u in
          (match constant_opt_value_in env (const, u) with
             | Some  body -> whrec (EConstr.of_constr body, stack)
             | None -> s)
      | LetIn (_,b,_,c) -> whrec (beta_applist sigma [b] c stack)
      | Cast (c,_,_) -> whrec (c, stack)
      | App (f,cl)  -> whrec (f, Array.fold_right (fun c accu -> c :: accu) cl stack)
      | Lambda (na,t,c) ->
          (match stack with
             | a :: stack -> whrec (beta_applist sigma [a] c stack)
             | _ -> s)

      | x -> s
  in
  whrec s

(* [red_elim_const] contracts iota/fix/cofix redexes hidden behind
   constants by keeping the name of the constants in the recursive calls;
   it fails if no redex is around *)

let rec red_elim_const env sigma ref u largs =
  let open ReductionBehaviour in
  let nargs = List.length largs in
  let largs, unfold_anyway, unfold_nonelim, nocase =
    match recargs ref with
    | None -> largs, false, false, false
    | Some NeverUnfold -> raise Redelimination
    | Some (UnfoldWhen { nargs = Some n } | UnfoldWhenNoMatch { nargs = Some n })
      when nargs < n -> raise Redelimination
    | Some (UnfoldWhen { recargs = x::l } | UnfoldWhenNoMatch { recargs = x::l })
      when nargs <= List.fold_left max x l -> raise Redelimination
    | Some (UnfoldWhen { recargs; nargs = None }) ->
      reduce_params env sigma largs recargs,
      false,
      false,
      false
    | Some (UnfoldWhenNoMatch { recargs; nargs = None }) ->
      reduce_params env sigma largs recargs,
      false,
      false,
      true
    | Some (UnfoldWhen { recargs; nargs = Some n }) ->
      let is_empty = List.is_empty recargs in
      reduce_params env sigma largs recargs,
      is_empty && nargs >= n,
      not is_empty && nargs >= n,
      false
    | Some (UnfoldWhenNoMatch { recargs; nargs = Some n }) ->
      let is_empty = List.is_empty recargs in
      reduce_params env sigma largs recargs,
      is_empty && nargs >= n,
      not is_empty && nargs >= n,
      true
  in
  try match reference_eval env sigma ref with
    | EliminationCases n when nargs >= n ->
        let c = reference_value env sigma ref u in
        let c', lrest = whd_nothing_for_iota env sigma (c, largs) in
        (special_red_case env sigma (EConstr.destCase sigma c'), lrest), nocase
    | EliminationProj n when nargs >= n ->
        let c = reference_value env sigma ref u in
        let c', lrest = whd_nothing_for_iota env sigma (c, largs) in
          (reduce_proj env sigma c', lrest), nocase
    | EliminationFix (min,minfxargs,infos) when nargs >= min ->
        let c = reference_value env sigma ref u in
        let d, lrest = whd_nothing_for_iota env sigma (c, largs) in
        let f = ([|Some (minfxargs,ref)|],infos), u, largs in
        (match reduce_fix_use_function env sigma f (destFix sigma d) lrest with
           | NotReducible -> raise Redelimination
           | Reduced (c,rest) -> (c, rest), nocase)
    | EliminationMutualFix (min,refgoal,refinfos) when nargs >= min ->
        let rec descend (ref,u) args =
          let c = reference_value env sigma ref u in
          if evaluable_reference_eq sigma ref refgoal then
            (c,args)
          else
            let c', lrest = whd_betalet_stack env sigma (applist(c,args)) in
            descend (destEvalRefU sigma c') lrest in
        let (_, midargs as s) = descend (ref,u) largs in
        let d, lrest = whd_nothing_for_iota env sigma s in
        let f = refinfos, u, midargs in
        (match reduce_fix_use_function env sigma f (destFix sigma d) lrest with
           | NotReducible -> raise Redelimination
           | Reduced (c,rest) -> (c, rest), nocase)
    | NotAnElimination when unfold_nonelim ->
         let c = reference_value env sigma ref u in
           (whd_betaiotazeta env sigma (applist (c, largs)), []), nocase
    | _ -> raise Redelimination
    with Redelimination when unfold_anyway ->
       let c = reference_value env sigma ref u in
         (whd_betaiotazeta env sigma (applist (c, largs)), []), nocase

and reduce_params env sigma stack l =
  let len = List.length stack in
    List.fold_left (fun stack i ->
      if len <= i then raise Redelimination
      else
        let arg = List.nth stack i in
        let rarg = whd_construct_stack env sigma arg in
          match EConstr.kind sigma (fst rarg) with
          | Construct _ | Int _ | Float _ | Array _ ->
             List.assign stack i (applist rarg)
          | _ -> raise Redelimination)
      stack l

(* reduce to whd normal form or to an applied constant that does not hide
   a reducible iota/fix/cofix redex (the "simpl" tactic) *)

and whd_simpl_stack env sigma =
  let open ReductionBehaviour in
  let rec redrec s =
    let s' = push_app sigma s in
    let (x, stack) = s' in
    match EConstr.kind sigma x with
      | Lambda (na,t,c) ->
          (match stack with
             | [] -> s'
             | a :: rest -> redrec (beta_applist sigma [a] c rest))
      | LetIn (n,b,t,c) -> redrec (Vars.substl [b] c, stack)
      | App (f,cl) -> assert false (* see push_app above *)
      | Cast (c,_,_) -> redrec (c, stack)
      | Case (ci,u,pms,p,iv,c,lf) ->
          (try
            redrec (special_red_case env sigma (ci,u,pms,p,iv,c,lf), stack)
          with
              Redelimination -> s')
      | Fix fix ->
          (try match reduce_fix env sigma fix stack with
            | Reduced s' -> redrec s'
            | NotReducible -> s'
          with Redelimination -> s')

      | Proj (p, c) ->
        (try
           let unf = Projection.unfolded p in
           if unf || is_evaluable env (EvalConstRef (Projection.constant p)) then
             let npars = Projection.npars p in
             (match unf, get (GlobRef.ConstRef (Projection.constant p)) with
              | false, Some NeverUnfold -> s'
              | false, Some (UnfoldWhen { recargs } | UnfoldWhenNoMatch { recargs })
                when not (List.is_empty recargs) ->
                let l' = List.map_filter (fun i ->
                    let idx = (i - (npars + 1)) in
                    if idx < 0 then None else Some idx) recargs in
                let stack = reduce_params env sigma stack l' in
                (match reduce_projection env sigma p ~npars
                         (whd_construct_stack env sigma c) stack
                 with
                 | Reduced s' -> redrec s'
                 | NotReducible -> s')
              | _ ->
                match reduce_projection env sigma p ~npars (whd_construct_stack env sigma c) stack with
                | Reduced s' -> redrec s'
                            | NotReducible -> s')
                 else s'
               with Redelimination -> s')

      | Const (cst, _) when is_primitive env cst ->
         (try
            let args =
              List.map_filter_i (fun i a ->
                  match a with CPrimitives.Kwhnf -> Some i | _ -> None)
                (CPrimitives.kind (Option.get (get_primitive env cst))) in
            let stack = reduce_params env sigma stack args in
            whd_const cst env sigma (applist (x, stack)), []
          with Redelimination -> s')

      | _ ->
        match match_eval_ref env sigma x stack with
        | Some (ref, u) ->
          (try
             let sapp, nocase = red_elim_const env sigma ref u stack in
             let hd, _ as s'' = redrec sapp in
             let rec is_case x = match EConstr.kind sigma x with
               | Lambda (_,_, x) | LetIn (_,_,_, x) | Cast (x, _,_) -> is_case x
               | App (hd, _) -> is_case hd
               | Case _ -> true
               | _ -> false in
               if nocase && is_case hd then raise Redelimination
               else s''
           with Redelimination -> s')
        | None -> s'
  in
  redrec

and reduce_fix env sigma fix stack =
  match fix_recarg fix stack with
    | None -> NotReducible
    | Some (recargnum,recarg) ->
        let (recarg'hd,_ as recarg') = whd_construct_stack env sigma recarg in
        let stack' = List.assign stack recargnum (applist recarg') in
        (match EConstr.kind sigma recarg'hd with
           | Construct _ -> Reduced (contract_fix sigma fix, stack')
           | _ -> NotReducible)

and reduce_fix_use_function env sigma f fix stack =
  match fix_recarg fix stack with
    | None -> NotReducible
    | Some (recargnum,recarg) ->
        let (recarg'hd,_ as recarg') =
          if EConstr.isRel sigma recarg then
            (* The recarg cannot be a local def, no worry about the right env *)
            (recarg, [])
          else
            whd_construct_stack env sigma recarg in
        let stack' = List.assign stack recargnum (applist recarg') in
        (match EConstr.kind sigma recarg'hd with
           | Construct _ ->
               Reduced (contract_fix_use_function env sigma f fix,stack')
           | _ -> NotReducible)

and reduce_proj env sigma c =
  let rec redrec s =
    match EConstr.kind sigma s with
    | Proj (proj, c) ->
      let c' = try redrec c with Redelimination -> c in
      let constr, cargs =  whd_construct_stack env sigma c' in
        (match EConstr.kind sigma constr with
        | Construct _ ->
          let proj_narg = Projection.npars proj + Projection.arg proj in
          List.nth cargs proj_narg
        | _ -> raise Redelimination)
    | Case (n,u,pms,p,iv,c,brs) ->
      let c' = redrec c in
      let p = (n,u,pms,p,iv,c',brs) in
        (try special_red_case env sigma p
         with Redelimination -> mkCase p)
    | _ -> raise Redelimination
  in redrec c

and special_red_case env sigma (ci, u, pms, p, iv, c, lf) =
  let rec redrec s =
    let (constr, cargs) = whd_simpl_stack env sigma s in
    match match_eval_ref env sigma constr cargs with
    | Some (ref, u) ->
      (match reference_opt_value env sigma ref u with
      | None -> raise Redelimination
      | Some gvalue ->
        if reducible_mind_case sigma gvalue then
          reduce_mind_case_use_function constr env sigma
          {mP=p; mU = u; mParams = pms; mconstr=gvalue; mcargs=cargs;
           mci=ci; mlf=lf}
        else
          redrec (gvalue, cargs))
    | None ->
      if reducible_mind_case sigma constr then
        reduce_mind_case env sigma
          {mP=p; mU = u; mParams = pms; mconstr=constr; mcargs=cargs;
          mci=ci; mlf=lf}
      else
        raise Redelimination
  in
  redrec (push_app sigma (c, []))

(* reduce until finding an applied constructor (or primitive value) or fail *)

and whd_construct_stack env sigma s =
  let (constr, cargs as s') = whd_simpl_stack env sigma (s, []) in
  if reducible_mind_case sigma constr || is_primitive_val sigma constr then s'
  else match match_eval_ref env sigma constr cargs with
  | Some (ref, u) ->
    (match reference_opt_value env sigma ref u with
    | None -> raise Redelimination
    | Some gvalue -> whd_construct_stack env sigma (applist(gvalue, cargs)))
  | _ -> raise Redelimination

(************************************************************************)
(*            Special Purpose Reduction Strategies                     *)

(* Red reduction tactic: one step of delta reduction + full
   beta-iota-fix-cofix-zeta-cast at the head of the conclusion of a
   sequence of products; fails if no delta redex is around
*)

let try_red_product env sigma c =
  let simpfun c = clos_norm_flags betaiotazeta env sigma c in
  let rec redrec env x =
    let x = whd_betaiota env sigma x in
    match EConstr.kind sigma x with
      | App (f,l) ->
          (match EConstr.kind sigma f with
             | Fix fix ->
                 (match fix_recarg fix (Array.to_list l) with
                    | None -> raise Redelimination
                    | Some (recargnum,recarg) ->
                        let recarg' = redrec env recarg in
                        let l = Array.copy l in
                        let () = Array.set l recargnum recarg' in
                        simpfun (mkApp (f, l)))
             | _ -> simpfun (mkApp (redrec env f, l)))
      | Cast (c,_,_) -> redrec env c
      | Prod (x,a,b) ->
          let open Context.Rel.Declaration in
          mkProd (x, a, redrec (push_rel (LocalAssum (x, a)) env) b)
      | LetIn (x,a,b,t) -> redrec env (Vars.subst1 a t)
      | Case (ci,u,pms,p,iv,d,lf) -> simpfun (mkCase (ci,u,pms,p,iv,redrec env d,lf))
      | Proj (p, c) ->
        let c' =
          match EConstr.kind sigma c with
          | Construct _ -> c
          | _ -> redrec env c
        in
        let npars = Projection.npars p in
          (match reduce_projection env sigma p ~npars (whd_betaiotazeta_stack env sigma c') [] with
          | Reduced s -> simpfun (applist s)
          | NotReducible -> raise Redelimination)
      | _ ->
        (match match_eval_ref env sigma x [] with
        | Some (ref, u) ->
          (* TO DO: re-fold fixpoints after expansion *)
          (* to get true one-step reductions *)
          (match reference_opt_value env sigma ref u with
             | None -> raise Redelimination
             | Some c -> c)
        | _ -> raise Redelimination)
  in redrec env c

let red_product env sigma c =
  try try_red_product env sigma c
  with Redelimination -> user_err Pp.(str "No head constant to reduce.")

(*
(* This old version of hnf uses betadeltaiota instead of itself (resp
   whd_construct_state) to reduce the argument of Case (resp Fix);
   The new version uses the "simpl" strategy instead. For instance,

   Variable n:nat.
   Eval hnf in match (plus (S n) O) with S n => n | _ => O end.

   returned

   (fix plus (n m : nat) {struct n} : nat :=
        match n with
        | O => m
        | S p => S (plus p m)
        end) n 0

   while the new version returns (plus n O)
 *)

let whd_simpl_orelse_delta_but_fix_old env sigma c =
  let whd_all = whd_all_state env sigma in
  let rec redrec (x, stack as s) =
    match kind_of_term x with
      | Lambda (na,t,c) ->
          (match decomp_stack stack with
             | None      -> s
             | Some (a,rest) -> stacklam redrec [a] c rest)
      | LetIn (n,b,t,c) -> stacklam redrec [b] c stack
      | App (f,cl)   -> redrec (f, append_stack cl stack)
      | Cast (c,_,_) -> redrec (c, stack)
      | Case (ci,p,d,lf) ->
          (try
             redrec (special_red_case env sigma whd_all (ci,p,d,lf), stack)
           with Redelimination ->
             s)
      | Fix fix ->
          (match reduce_fix whd_all fix stack with
             | Reduced s' -> redrec s'
             | NotReducible -> s)
      | _ when isEvalRef env x ->
          let ref = destEvalRef x in
          (try
            redrec (red_elim_const env sigma ref stack)
           with Redelimination ->
             match reference_opt_value env sigma ref with
               | Some c ->
                   (match kind_of_term (strip_lam c) with
                     | CoFix _ | Fix _ -> s
                     | _ -> redrec (c, stack))
               | None -> s)
      | _ -> s
  in app_stack (redrec (c, empty_stack))
*)

(* Same as [whd_simpl] but also reduces constants that do not hide a
   reducible fix, but does this reduction of constants only until it
   immediately hides a non reducible fix or a cofix *)

let whd_simpl_orelse_delta_but_fix env sigma c =
  let rec redrec s =
    let (constr, stack as s') = whd_simpl_stack env sigma s in
    match match_eval_ref_value env sigma constr stack with
    | Some c ->
      (match EConstr.kind sigma (snd (decompose_lam sigma c)) with
      | CoFix _ | Fix _ -> s'
      | Proj (p,t) when
          (match EConstr.kind sigma constr with
          | Const (c', _) -> Constant.CanOrd.equal (Projection.constant p) c'
          | _ -> false) ->
        let npars = Projection.npars p in
          if List.length stack <= npars then
            (* Do not show the eta-expanded form *)
            s'
          else redrec (c, stack)
      | _ -> redrec (c, stack))
    | None -> s'
  in
  applist (redrec c)

let hnf_constr0 env sigma c =
  whd_simpl_orelse_delta_but_fix env sigma (c, [])

let hnf_constr env sigma c =
  let c = whd_simpl_orelse_delta_but_fix env sigma (c, []) in
  clos_norm_flags betaiota env sigma c

(* The "simpl" reduction tactic *)

let whd_simpl env sigma c =
  applist (whd_simpl_stack env sigma (c, []))

let simpl env sigma c =
  let rec strongrec env t =
    map_constr_with_full_binders env sigma push_rel strongrec env (whd_simpl env sigma t) in
  strongrec env c

(* Reduction at specific subterms *)

let matches_head env sigma c t =
  let t, l = decompose_app sigma t in
  match EConstr.kind sigma t, l with
    | Proj (p, _), _ -> Constr_matching.matches env sigma c (mkConstU (Projection.constant p, EInstance.empty))
    | _, _::_ -> Constr_matching.matches env sigma c t
    | _ -> raise Constr_matching.PatternMatchingFailure

(** FIXME: Specific function to handle projections: it ignores what happens on the
    parameters. This is a temporary fix while rewrite etc... are not up to equivalence
    of the projection and its eta expanded form.
*)
let change_map_constr_with_binders_left_to_right g f (env, l as acc) sigma c =
  match EConstr.kind sigma c with
  | Proj (p, r) -> (* Treat specially for partial applications *)
    let t = Retyping.expand_projection env sigma p r [] in
    let hdf, al = destApp sigma t in
    let a = al.(Array.length al - 1) in
    let app = (mkApp (hdf, Array.sub al 0 (Array.length al - 1))) in
    let app' = f acc app in
    let a' = f acc a in
    let hdf', _ = decompose_app_vect sigma app' in
    if hdf' == hdf then
      (* Still the same projection, we ignore the change in parameters *)
      mkProj (p, a')
    else mkApp (app', [| a' |])
  | _ -> map_constr_with_binders_left_to_right env sigma g f acc c

let e_contextually byhead (occs,c) f = begin fun env sigma t ->
  let count = ref (Locusops.initialize_occurrence_counter occs) in
  (* FIXME: we do suspicious things with this evarmap *)
  let evd = ref sigma in
  let rec traverse nested (env,c as envc) t =
    if Locusops.occurrences_done !count then (* Shortcut *) t
    else
    try
      let subst =
        if byhead then matches_head env sigma c t
        else Constr_matching.matches env sigma c t in
      let ok, count' = Locusops.update_occurrence_counter !count in count := count';
      if ok then begin
        if Option.has_some nested then
          user_err Pp.(str "The subterm at occurrence " ++ int (Option.get nested) ++ str " overlaps with the subterm at occurrence " ++ int (Locusops.current_occurrence !count) ++ str ".");
        (* Skip inner occurrences for stable counting of occurrences *)
        if Locusops.more_specific_occurrences !count then
          ignore (traverse_below (Some (Locusops.current_occurrence !count)) envc t);
        let (evm, t) = (f subst) env !evd t in
        (evd := evm; t)
      end
      else
        traverse_below nested envc t
    with Constr_matching.PatternMatchingFailure ->
      traverse_below nested envc t
  and traverse_below nested envc t =
    (* when byhead, find other occurrences without matching again partial
       application with same head *)
    match EConstr.kind !evd t with
    | App (f,l) when byhead -> mkApp (f, Array.map_left (traverse nested envc) l)
    | Proj (p,c) when byhead -> mkProj (p,traverse nested envc c)
    | _ ->
        change_map_constr_with_binders_left_to_right
          (fun d (env,c) -> (push_rel d env, Patternops.lift_pattern 1 c))
          (traverse nested) envc sigma t
  in
  let t' = traverse None (env,c) t in
  Locusops.check_used_occurrences !count;
  (!evd, t')
  end

let contextually byhead occs f env sigma t =
  let f' subst env sigma t = sigma, f subst env sigma t in
  snd (e_contextually byhead occs f' env sigma t)

(* linear bindings (following pretty-printer) of the value of name in c.
 * n is the number of the next occurrence of name.
 * ol is the occurrence list to find. *)

let match_constr_evaluable_ref sigma c evref =
  match EConstr.kind sigma c, evref with
  | Const (c,u), EvalConstRef c' when Constant.CanOrd.equal c c' -> Some u
  | Var id, EvalVarRef id' when Id.equal id id' -> Some EInstance.empty
  | _, _ -> None

let substlin env sigma evalref occs c =
  let count = ref (Locusops.initialize_occurrence_counter occs) in
  let value u = value_of_evaluable_ref env evalref u in
  let rec substrec () c =
    if Locusops.occurrences_done !count then c
    else
      match match_constr_evaluable_ref sigma c evalref with
      | Some u ->
        let ok, count' = Locusops.update_occurrence_counter !count in
        count := count';
        if ok then value u else c
      | None ->
        map_constr_with_binders_left_to_right env sigma
          (fun _ () -> ())
          substrec () c
  in
  let t' = substrec () c in
  Locusops.check_used_occurrences !count;
  (Locusops.current_occurrence !count, t')

let string_of_evaluable_ref env = function
  | EvalVarRef id -> Id.to_string id
  | EvalConstRef kn ->
      Libnames.string_of_qualid
        (Nametab.shortest_qualid_of_global (vars_of_env env) (GlobRef.ConstRef kn))

(* Removing fZETA for finer behaviour would break many developments *)
let unfold_side_flags = RedFlags.[fBETA;fMATCH;fFIX;fCOFIX;fZETA]
let unfold_side_red = RedFlags.(mkflags [fBETA;fMATCH;fFIX;fCOFIX;fZETA])
let unfold_red kn =
  let flag = match kn with
    | EvalVarRef id -> RedFlags.fVAR id
    | EvalConstRef kn -> RedFlags.fCONST kn in
  RedFlags.mkflags (flag::RedFlags.fDELTA::unfold_side_flags)

let unfold env sigma name c =
  if is_evaluable env name then
    clos_norm_flags (unfold_red name) env sigma c
  else
    user_err Pp.(str (string_of_evaluable_ref env name^" is opaque."))

(* [unfoldoccs : (readable_constraints -> (int list * full_path) -> constr -> constr)]
 * Unfolds the constant name in a term c following a list of occurrences occl.
 * at the occurrences of occ_list. If occ_list is empty, unfold all occurrences.
 * Performs a betaiota reduction after unfolding. *)
let unfoldoccs env sigma (occs,name) c =
  let open Locus in
  match occs with
  | NoOccurrences -> c
  | AllOccurrences -> unfold env sigma name c
  | OnlyOccurrences _ | AllOccurrencesBut _ | AtLeastOneOccurrence ->
    let (occ,uc) = substlin env sigma name occs c in
    if Int.equal occ 0 then
      user_err Pp.(str ((string_of_evaluable_ref env name)^" does not occur."));
    nf_betaiotazeta env sigma uc

(* Unfold reduction tactic: *)
let unfoldn loccname env sigma c =
  List.fold_left (fun c occname -> unfoldoccs env sigma occname c) c loccname

(* Re-folding constants tactics: refold com in term c *)
let fold_one_com com env sigma c =
  let rcom = red_product env sigma com in
  (* Reason first on the beta-iota-zeta normal form of the constant as
     unfold produces it, so that the "unfold f; fold f" configuration works
     to refold fix expressions *)
  let a = subst_term sigma (clos_norm_flags unfold_side_red env sigma rcom) c in
  if not (EConstr.eq_constr sigma a c) then
    Vars.subst1 com a
  else
    (* Then reason on the non beta-iota-zeta form for compatibility -
       even if it is probably a useless configuration *)
    let a = subst_term sigma rcom c in
    Vars.subst1 com a

let fold_commands cl env sigma c =
  List.fold_right (fun com c -> fold_one_com com env sigma c) (List.rev cl) c


(* call by value reduction functions *)
let cbv_norm_flags flags env sigma t =
  Cbv.(cbv_norm (create_cbv_infos flags env sigma) t)

let cbv_beta = cbv_norm_flags beta
let cbv_betaiota = cbv_norm_flags betaiota
let cbv_betadeltaiota env sigma =  cbv_norm_flags all env sigma

let compute = cbv_betadeltaiota

(* Pattern *)

(* gives [na:ta]c' such that c converts to ([na:ta]c' a), abstracting only
 * the specified occurrences. *)

let abstract_scheme env (locc,a) (c, sigma) =
  let ta = Retyping.get_type_of env sigma a in
  let sigma, ta = Evarsolve.refresh_universes ~onlyalg:true (Some false) env sigma ta in
  let na = Namegen.named_hd env sigma ta Anonymous in
  let na = make_annot na Sorts.Relevant in (* TODO relevance *)
  if occur_meta sigma ta then user_err Pp.(str "Cannot find a type for the generalisation.");
  if occur_meta sigma a then
    mkLambda (na,ta,c), sigma
  else
    let c', sigma = Find_subterm.subst_closed_term_occ env sigma (Locus.AtOccs locc) a c in
      mkLambda (na,ta,c'), sigma

let pattern_occs loccs_trm = begin fun env sigma c ->
  let abstr_trm, sigma = List.fold_right (abstract_scheme env) loccs_trm (c,sigma) in
  try
    let sigma, _ = Typing.type_of env sigma abstr_trm in
    (sigma, applist(abstr_trm, List.map snd loccs_trm))
  with Type_errors.TypeError (env',t) ->
    raise (ReductionTacticError (InvalidAbstraction (env,sigma,abstr_trm,(env',t))))
  end

(* Used in several tactics. *)

let check_privacy env ind =
  let spec = Inductive.lookup_mind_specif env ind in
  if Inductive.is_private spec then
    user_err Pp.(str "case analysis on a private type.")

(* put t as t'=(x1:A1)..(xn:An)B with B an inductive definition of name name
   return name, B and t' *)

let reduce_to_ind_gen allow_product env sigma t =
  let rec elimrec env t l =
    let t = hnf_constr0 env sigma t in
    match EConstr.kind sigma (fst (decompose_app_vect sigma t)) with
      | Ind (ind, _ as indu) ->
        let t = nf_betaiota env sigma t in
        check_privacy env ind; (indu, it_mkProd_or_LetIn t l)
      | Prod (n,ty,t') ->
          let open Context.Rel.Declaration in
          if allow_product then
            let ty = nf_betaiota env sigma ty in
            elimrec (push_rel (LocalAssum (n,ty)) env) t' ((LocalAssum (n,ty))::l)
          else
            user_err Pp.(str"Not an inductive definition.")
      | _ ->
          (* Last chance: we allow to bypass the Opaque flag (as it
             was partially the case between V5.10 and V8.1 *)
          let t' = whd_all env sigma t in
          match EConstr.kind sigma (fst (decompose_app_vect sigma t')) with
            | Ind (ind, _ as indu) -> check_privacy env ind; (indu, it_mkProd_or_LetIn t' l)
            | _ -> user_err Pp.(str"Not an inductive product.")
  in
  elimrec env t []

let reduce_to_quantified_ind env sigma c = reduce_to_ind_gen true env sigma c
let reduce_to_atomic_ind env sigma c = reduce_to_ind_gen false env sigma c

let eval_to_quantified_ind env sigma t =
  let rec elimrec env t =
    let t = hnf_constr0 env sigma t in
    match EConstr.kind sigma (fst (decompose_app_vect sigma t)) with
      | Ind (ind, _ as indu) ->
        let () = check_privacy env ind in
        indu
      | Prod (n,ty,t') ->
        elimrec (push_rel (Context.Rel.Declaration.LocalAssum (n,ty)) env) t'
      | _ ->
          (* Last chance: we allow to bypass the Opaque flag (as it
             was partially the case between V5.10 and V8.1 *)
          let t' = whd_all env sigma t in
          match EConstr.kind sigma (fst (decompose_app_vect sigma t')) with
            | Ind (ind, _ as indu) -> check_privacy env ind; indu
            | _ -> user_err Pp.(str"Not an inductive product.")
  in
  elimrec env t

let find_hnf_rectype env sigma t =
  let ind,t = reduce_to_atomic_ind env sigma t in
  ind, snd (decompose_app sigma t)

(* Reduce the weak-head redex [beta,iota/fix/cofix[all],cast,zeta,simpl/delta]
   or raise [NotStepReducible] if not a weak-head redex *)

exception NotStepReducible

let one_step_reduce env sigma c =
  let rec redrec (x, stack) =
    match EConstr.kind sigma x with
      | Lambda (n,t,c)  ->
          (match stack with
             | []        -> raise NotStepReducible
             | a :: rest -> (Vars.subst1 a c, rest))
      | App (f,cl) -> redrec (f, (Array.to_list cl)@stack)
      | LetIn (_,f,_,cl) -> (Vars.subst1 f cl,stack)
      | Cast (c,_,_) -> redrec (c,stack)
      | Case (ci,u,pms,p,iv,c,lf) ->
          (try
             (special_red_case env sigma (ci,u,pms,p,iv,c,lf), stack)
           with Redelimination -> raise NotStepReducible)
      | Fix fix ->
          (try match reduce_fix env sigma fix stack with
             | Reduced s' -> s'
             | NotReducible -> raise NotStepReducible
           with Redelimination -> raise NotStepReducible)
      | _ when isEvalRef env sigma x ->
          let ref,u = destEvalRefU sigma x in
          (try
             fst (red_elim_const env sigma ref u stack)
           with Redelimination ->
             match reference_opt_value env sigma ref u with
               | Some d -> (d, stack)
               | None -> raise NotStepReducible)

      | _ -> raise NotStepReducible
  in
  applist (redrec (c,[]))

let error_cannot_recognize ref =
  user_err
    Pp.(str "Cannot recognize a statement based on " ++
        Nametab.pr_global_env Id.Set.empty ref ++ str".")

let reduce_to_ref_gen allow_product env sigma ref t =
  if Globnames.isIndRef ref then
    let ((mind,u),t) = reduce_to_ind_gen allow_product env sigma t in
    begin match ref with
    | GlobRef.IndRef mind' when Ind.CanOrd.equal mind mind' -> t
    | _ -> error_cannot_recognize ref
    end
  else
  (* lazily reduces to match the head of [t] with the expected [ref] *)
  let rec elimrec env t l =
    let c, _ = decompose_app_vect sigma t in
    match EConstr.kind sigma c with
      | Prod (n,ty,t') ->
          if allow_product then
            let open Context.Rel.Declaration in
            elimrec (push_rel (LocalAssum (n,ty)) env) t' ((LocalAssum (n,ty))::l)
          else
            error_cannot_recognize ref
      | _ ->
        if isRefX sigma ref c
        then it_mkProd_or_LetIn t l
        else
          try
            let t' = nf_betaiota env sigma (one_step_reduce env sigma t) in
            elimrec env t' l
          with NotStepReducible -> error_cannot_recognize ref
  in
  elimrec env t []

let reduce_to_quantified_ref = reduce_to_ref_gen true
let reduce_to_atomic_ref = reduce_to_ref_gen false
