(*i camlp4deps: "parsing/grammar.cma" i*)
(*i camlp4use: "pa_extend.cmp" i*)

open Format
open Term
open Coqlib
open Tacmach
open Tacticals
open Tactics
open Pp
open Flags

open Nameops
open Entries
open Topconstr
open Printing
module DK = Decl_kinds

type inductive_kind = Simple | Recursive | Mutual
let pr_kind = function
  | Simple -> str "Simple"
  | Recursive -> str "Recursive"
  | Mutual -> str "Mutual"

let print_id fmt id =
  fprintf fmt "%s" (Names.string_of_id id)

let iter3 a a' a'' f =
  for i = 0 to (Array.length a - 1) do
    f i a.(i) a'.(i) a''.(i)
  done

let print_ind_body fmt ibody =
  let module D = Declarations in
    fprintf fmt "Inductive body : {\n";
    fprintf fmt "\t name : %a\n" print_id ibody.D.mind_typename;
    fprintf fmt "\t constructors : \n";
    iter3 ibody.D.mind_consnames ibody.D.mind_nf_lc ibody.D.mind_consnrealdecls
      (fun i id typ n -> fprintf fmt "\t #%d : %a [%d arguments] == %a\n"
	 i print_id id n print_constr typ);
    fprintf fmt "}\n"

let dl id = Util.dummy_loc, id
let cf cexpr = false, cexpr
let cprop = CSort (Util.dummy_loc, Glob_term.GProp Term.Null)
let ccomparison = mkIdentC (Names.id_of_string "comparison")
let bin_rel_t id_t =
  CArrow (Util.dummy_loc, mkIdentC id_t,
	  CArrow (Util.dummy_loc, mkIdentC id_t, cprop))
let bin_cmp_t id_t =
  CArrow (Util.dummy_loc, mkIdentC id_t,
	  CArrow (Util.dummy_loc, mkIdentC id_t, ccomparison))

let hole = CHole (Util.dummy_loc, None)

(* à la v8.2... *)
let declare_definition
    id (loc, boxed_flag, def_obj_kind)
    binder_list red_expr_opt constr_expr
    constr_expr_opt decl_hook =
  let (def_entry, man_impl) =
    Command.interp_definition binder_list red_expr_opt constr_expr
      constr_expr_opt
  in
    Command.declare_definition
      id (loc, def_obj_kind) def_entry man_impl decl_hook

(* building the equality predicate *)
let equiv_ref =
  Libnames.Qualid (dl (Libnames.qualid_of_string "Equivalence.equiv"))
let mk_equiv x y =
  CApp (Util.dummy_loc, (None, mkRefC equiv_ref),
(* 			 mkIdentC (Names.id_of_string "equiv")), *)
	[mkIdentC x, None; mkIdentC y, None])

let rec app_expl_i acc base n =
  match n with
    | 0 -> acc
    | n ->
	let xn = Nameops.make_ident base (Some n) in
	  app_expl_i ((mkIdentC xn, None)::acc) base (n-1)

let rec prod_n_i acc n =
  match n with
    | 0 -> acc
    | n ->
	let xn = Names.Name (Nameops.make_ident "x" (Some n)) in
	let yn = Names.Name (Nameops.make_ident "y" (Some n)) in
	  prod_n_i (([dl xn; dl yn], Default Glob_term.Explicit, hole)::acc)
	    (n-1)

let eq_constr_i eqid cid carity =
  let xbar = app_expl_i [] "x" carity in
  let ybar = app_expl_i [] "y" carity in
  let cx = CApp (Util.dummy_loc, (None, mkIdentC cid), xbar) in
  let cy = CApp (Util.dummy_loc, (None, mkIdentC cid), ybar) in
  let rec eq_n_i acc n =
    match n with
      | 0 -> acc
      | n ->
	  let xn = Nameops.make_ident "x" (Some n) in
	  let yn = Nameops.make_ident "y" (Some n) in
	    eq_n_i
	      (CArrow (Util.dummy_loc,
		       mk_equiv xn yn,
		       acc))
	      (n-1)
  in
    CProdN (Util.dummy_loc, (prod_n_i [] carity),
	    eq_n_i
	      (CApp (Util.dummy_loc, (None, mkIdentC eqid),
		     [cx, None; cy, None])) carity)

let make_eq_mutual ind mind body =
  let id_t = body.Declarations.mind_typename in
  let id_eq = add_suffix id_t "_eq" in
  let lconstr =
    List.map2 (fun cid carity ->
		 (cf (dl (add_suffix id_eq ("_"^(Names.string_of_id cid))),
		      eq_constr_i id_eq cid carity)))
      (Array.to_list body.Declarations.mind_consnames)
      (Array.to_list body.Declarations.mind_consnrealdecls)
  in
    [(dl id_eq, [], Some (bin_rel_t id_t) , lconstr), []]

(* building the ordering predicate *)
let lt_StrictOrder_ref =
  Libnames.Qualid
    (dl (Libnames.qualid_of_string "Containers.OrderedType.lt_StrictOrder"))
let mk_lt x y =
  CApp (Util.dummy_loc, (None, mkRefC lt_StrictOrder_ref),
	[mkIdentC x, None; mkIdentC y, None])

let lexi_constr ltid cid carity =
  let xbar = app_expl_i [] "x" carity in
  let ybar = app_expl_i [] "y" carity in
  let cx = CApp (Util.dummy_loc, (None, mkIdentC cid), xbar) in
  let cy = CApp (Util.dummy_loc, (None, mkIdentC cid), ybar) in
  let rec one_lexico_case acc = function
    | 0 -> acc
    | n ->
	let xn = Nameops.make_ident "x" (Some n) in
	let yn = Nameops.make_ident "y" (Some n) in
	  one_lexico_case
	    (CArrow (Util.dummy_loc, mk_equiv xn yn, acc)) (n-1) in
  let rec all_lexico_cases goal acc = function
    | 0 -> acc
    | n ->
	let xn = Nameops.make_ident "x" (Some n) in
	let yn = Nameops.make_ident "y" (Some n) in
	let base = CArrow (Util.dummy_loc, mk_lt xn yn, goal) in
	let c = one_lexico_case base (n-1) in
	let name = add_suffix ltid ("_"^(Names.string_of_id cid)^
				      "_"^(string_of_int n)) in
	  all_lexico_cases goal ((name, c)::acc) (n-1) in
  let goal =
    CApp (Util.dummy_loc, (None, mkIdentC ltid), [cx, None; cy, None]) in
  let cases =
    all_lexico_cases goal [] carity in
    List.map (fun (name, c) ->
		cf (dl name,
		    CProdN (Util.dummy_loc, (prod_n_i [] carity), c)))
      cases

let inter_constr ltid cid carity otherids otherarities =
  let xbar = app_expl_i [] "x" carity in
  let cx = CApp (Util.dummy_loc, (None, mkIdentC cid), xbar) in
  let aux id ar =
    let ybar = app_expl_i [] "y" ar in
    let cy = CApp (Util.dummy_loc, (None, mkIdentC id), ybar) in
    let goal =
      CApp (Util.dummy_loc, (None, mkIdentC ltid), [cx, None; cy, None]) in
    let name =
      add_suffix ltid ("_"^(Names.string_of_id cid)^
			 "_"^(Names.string_of_id id)) in
    let rec prod acc v = function
      | 0 -> acc
      | n -> let xn = Names.Name (Nameops.make_ident v (Some n)) in
	  prod (([dl xn], Default Glob_term.Explicit, hole)::acc) v (n-1)
    in
    let foralls1 = prod [] "y" ar in
    let foralls = prod foralls1 "x" carity in
      cf (dl name, CProdN (Util.dummy_loc, foralls, goal))
  in
    List.map2 aux otherids otherarities

let rec lt_constr ltid names arities =
  match names, arities with
    | [], [] -> []
    | cid::otherids, carity::otherars ->
	let lexi = lexi_constr ltid cid carity in
	let inter = inter_constr ltid cid carity otherids otherars in
	  lexi@inter@(lt_constr ltid otherids otherars)
    | _, _ -> failwith "Lists should have the same lengths."

let make_lt_mutual ind mind body =
  let id_t = body.Declarations.mind_typename in
  let id_lt = add_suffix id_t "_lt" in
  let names = Array.to_list body.Declarations.mind_consnames in
  let decls = Array.to_list body.Declarations.mind_consnrealdecls in
  let lconstr = lt_constr id_lt names decls in
    [(dl id_lt, [], Some (bin_rel_t id_t) , lconstr), []]

(* building the comparison function *)
let ref_Eq = Libnames.Ident (dl (Names.id_of_string "Eq"))
let ref_Lt = Libnames.Ident (dl (Names.id_of_string "Lt"))
let ref_Gt = Libnames.Ident (dl (Names.id_of_string "Gt"))
let id_Eq = Names.id_of_string "Eq"
let id_Lt = Names.id_of_string "Lt"
let id_Gt = Names.id_of_string "Gt"

let compare_ref =
  Libnames.Qualid
    (dl (Libnames.qualid_of_string "Containers.OrderedType.compare"))
let mk_cmp x y =
  CApp (Util.dummy_loc, (None, mkRefC compare_ref),
	[mkIdentC x, None; mkIdentC y, None])

let pathole = CPatAtom (Util.dummy_loc, None)
let rec lholes = function
  | 0 -> []
  | n -> pathole::(lholes (n-1))
let patc r l = CPatCstr (Util.dummy_loc, r, l)
let rec lpats v acc = function
  | 0 -> acc
  | n ->
      let p = CPatAtom (Util.dummy_loc,
			Some (Libnames.Ident
				(dl (Nameops.make_ident v (Some n))))) in
	lpats v (p::acc) (n-1)

let rec lvars acc base n =
  match n with
    | 0 -> acc
    | n ->
	let xn = Nameops.make_ident base (Some n) in
	  lvars (xn::acc) base (n-1)

let lexi_eqn_constr r carity =
  let rec branch xs ys =
    match xs, ys with
      | [], [] -> mkIdentC id_Eq
      | [x], [y] -> mk_cmp x y
      | x::xs, y::ys ->
	  let item = [(mk_cmp x y, (None, None))] in
	  let brlt =
	    (Util.dummy_loc,
	     [(Util.dummy_loc, [patc ref_Lt []])],
	     mkIdentC id_Lt) in
	  let breq =
	    (Util.dummy_loc,
	     [(Util.dummy_loc, [patc ref_Eq []])],
	     branch xs ys) in
	  let brgt =
	    (Util.dummy_loc,
	     [(Util.dummy_loc, [patc ref_Gt []])],
	     mkIdentC id_Gt) in
	    CCases (Util.dummy_loc, RegularStyle, None, item,
		    [brlt; breq; brgt])
      | _, _ -> failwith "Lists should have the same size"
  in
  let xbar = lvars [] "x" carity in
  let ybar = lvars [] "y" carity in
    (Util.dummy_loc,
     [(Util.dummy_loc, [patc r (lpats "x" [] carity);
			patc r (lpats "y" [] carity)])],
     branch xbar ybar)

let rec branches_constr cmpid names arities =
  match names, arities with
    | [], [] -> []
    | [cid], [carity] ->
	let r = Libnames.Ident (dl cid) in
	let eqn_lexi = lexi_eqn_constr r carity in
	  [eqn_lexi]
    | cid::otherids, carity::otherars ->
	let r = Libnames.Ident (dl cid) in
	let eqn_lexi = lexi_eqn_constr r carity in
	let eqn_inter1 =
	  (Util.dummy_loc,
	   [(Util.dummy_loc, [patc r (lholes carity); pathole])],
	   mkIdentC id_Lt) in
	let eqn_inter2 =
	  (Util.dummy_loc,
	   [(Util.dummy_loc, [pathole; patc r (lholes carity)])],
	   mkIdentC id_Gt) in
	  eqn_lexi::eqn_inter1::eqn_inter2::
	    (branches_constr cmpid otherids otherars)
    | _, _ -> failwith "Lists should have the same lengths."

let make_cmp_def ind mind body =
  let id_t = body.Declarations.mind_typename in
  let id_cmp = add_suffix id_t "_cmp" in
  let names = Array.to_list body.Declarations.mind_consnames in
  let decls = Array.to_list body.Declarations.mind_consnrealdecls in
  let x = Nameops.make_ident "x" None in
  let y = Nameops.make_ident "y" None in
  let items = [(mkIdentC x, (None, None));
	       (mkIdentC y, (None, None))] in
  let branches = branches_constr id_cmp names decls in
  let body =  CCases (Util.dummy_loc, RegularStyle, None, items, branches) in
  let def =
    CLambdaN (Util.dummy_loc,
	      [([dl (Names.Name x); dl (Names.Name y)],
		Default Glob_term.Explicit,
		mkIdentC id_t)],
	      body) in
    id_cmp, def

(* proving that the equality is an [Equivalence] *)
let load_tactic s =
  Tacinterp.interp
    (Tacexpr.TacArg
       (Util.dummy_loc, Tacexpr.Reference
	  (Libnames.Ident (dl (Names.id_of_string s)))))

let load_tactic_args s lids =
  let args =
    List.map (fun id -> Tacexpr.Reference (Libnames.Ident (dl id))) lids
  in
    Tacinterp.interp
      (Tacexpr.TacArg
	 (Util.dummy_loc, Tacexpr.TacCall (Util.dummy_loc,
			   Libnames.Ident (dl (Names.id_of_string s)),
			   args)))

open Tacticals
let prove_refl indconstr mind body =
  let id_t = body.Declarations.mind_typename in
  let id_eq = add_suffix id_t "_eq" in
  let x = Nameops.make_ident "x" None in
  let ceq = Libnames.constr_of_reference
    (Nametab.global (Libnames.Ident (dl id_eq))) in
  let goal =
    mkNamedProd x indconstr
      (mkApp (ceq, [| mkVar x; mkVar x |])) in
  let refltactic =
    load_tactic "rinductive_refl"
  in
    Lemmas.start_proof (add_suffix id_t "_eq_refl")
      (DK.Global, DK.Proof DK.Property) goal (fun _ _ -> ());
    Pfedit.by refltactic;
    Lemmas.save_named true

let prove_sym indconstr mind body =
  let id_t = body.Declarations.mind_typename in
  let id_eq = add_suffix id_t "_eq" in
  let x = Nameops.make_ident "x" None in
  let y = Nameops.make_ident "y" None in
  let ceq = Libnames.constr_of_reference
    (Nametab.global (Libnames.Ident (dl id_eq))) in
  let goal =
    mkNamedProd x indconstr
      (mkNamedProd y indconstr
	 (mkArrow
	    (mkApp (ceq, [| mkVar x; mkVar y |]))
	    (mkApp (ceq, [| mkVar y; mkVar x |])))) in
  let symtactic =
    load_tactic "rinductive_sym"
  in
    Lemmas.start_proof (add_suffix id_t "_eq_sym")
      (DK.Global, DK.Proof DK.Property) goal (fun _ _ -> ());
    Pfedit.by symtactic;
    Lemmas.save_named true

let prove_trans indconstr mind body =
  let id_t = body.Declarations.mind_typename in
  let id_eq = add_suffix id_t "_eq" in
  let x = Nameops.make_ident "x" None in
  let y = Nameops.make_ident "y" None in
  let z = Nameops.make_ident "z" None in
  let ceq = Libnames.constr_of_reference
    (Nametab.global (Libnames.Ident (dl id_eq))) in
  let goal =
    mkNamedProd x indconstr
      (mkNamedProd y indconstr
	 (mkNamedProd z indconstr
	    (mkArrow
	       (mkApp (ceq, [| mkVar x; mkVar y |]))
	       (mkArrow
		  (mkApp (ceq, [| mkVar y; mkVar z |]))
		  (mkApp (ceq, [| mkVar x; mkVar z |]))
	       )))) in
  let transtactic =
    load_tactic "rinductive_trans"
  in
    Lemmas.start_proof (add_suffix id_t "_eq_trans")
      (DK.Global, DK.Proof DK.Property) goal (fun _ _ -> ());
    Pfedit.by transtactic;
    Lemmas.save_named true

let prove_Equivalence indconstr mind body =
  prove_refl indconstr mind body;
  prove_sym indconstr mind body;
  prove_trans indconstr mind body;
  let id_t = body.Declarations.mind_typename in
  let id_equiv = add_suffix id_t "_eq_Equivalence" in
  let equiv =
    CApp (Util.dummy_loc,
	  (None, mkIdentC (Names.id_of_string "Build_Equivalence")),
	  [hole, None; hole, None;
	   mkIdentC (add_suffix id_t "_eq_refl"), None;
	   mkIdentC (add_suffix id_t "_eq_sym"), None;
	   mkIdentC (add_suffix id_t "_eq_trans"), None])
  in
    declare_definition id_equiv
      (Decl_kinds.Global, false, Decl_kinds.Definition)
      [] None equiv None (fun _ _ -> ())(* ; *)
(*     Classes.declare_instance false (dl id_equiv) *)

(* proving that the ordering is a [StrictOrder] *)
let prove_lt_trans indconstr mind body =
  let id_t = body.Declarations.mind_typename in
  let id_lt = add_suffix id_t "_lt" in
  let id_eq = add_suffix id_t "_eq" in
  let x = Nameops.make_ident "x" None in
  let y = Nameops.make_ident "y" None in
  let z = Nameops.make_ident "z" None in
  let clt = Libnames.constr_of_reference
    (Nametab.global (Libnames.Ident (dl id_lt))) in
  let ceq = Libnames.constr_of_reference
    (Nametab.global (Libnames.Ident (dl id_eq))) in
  let prove_eq_lt_and_gt () =
    let id_eq_sym = add_suffix id_t "_eq_sym" in
    let id_eq_trans = add_suffix id_t "_eq_trans" in
    let lemma_eq_lt =
      mkNamedProd x indconstr
	(mkNamedProd y indconstr
	   (mkNamedProd z indconstr
	      (mkArrow
		 (mkApp (ceq, [| mkVar x; mkVar y |]))
		 (mkArrow
		    (mkApp (clt, [| mkVar x; mkVar z |]))
		    (mkApp (clt, [| mkVar y; mkVar z |]))
		 )))) in
    let solve_eq_lt =
      load_tactic_args "rinductive_eq_lt" [id_eq_sym; id_eq_trans]
    in
    let lemma_eq_gt =
      mkNamedProd x indconstr
	(mkNamedProd y indconstr
	   (mkNamedProd z indconstr
	      (mkArrow
		 (mkApp (ceq, [| mkVar x; mkVar y |]))
		 (mkArrow
		    (mkApp (clt, [| mkVar z; mkVar x |]))
		    (mkApp (clt, [| mkVar z; mkVar y |]))
		 )))) in
    let solve_eq_gt =
      load_tactic_args "rinductive_eq_gt" [id_eq_trans]
    in
      Lemmas.start_proof (add_suffix id_t "_eq_lt")
	(DK.Global, DK.Proof DK.Lemma) lemma_eq_lt (fun _ _ -> ());
      Pfedit.by solve_eq_lt;
      Lemmas.save_named true;
      Lemmas.start_proof (add_suffix id_t "_eq_gt")
	(DK.Global, DK.Proof DK.Lemma) lemma_eq_gt (fun _ _ -> ());
      Pfedit.by solve_eq_gt;
      Lemmas.save_named true
  in
  let goal =
    mkNamedProd x indconstr
      (mkNamedProd y indconstr
	 (mkNamedProd z indconstr
	    (mkArrow
	       (mkApp (clt, [| mkVar x; mkVar y |]))
	       (mkArrow
		  (mkApp (clt, [| mkVar y; mkVar z |]))
		  (mkApp (clt, [| mkVar x; mkVar z |]))
	       )))) in
  let transtactic =
    load_tactic_args "rinductive_lexico_trans"
      [add_suffix id_t "_eq_sym"; add_suffix id_t "_eq_trans";
       add_suffix id_t "_eq_gt"; add_suffix id_t "_eq_lt"]
  in
  prove_eq_lt_and_gt ();
  Lemmas.start_proof (add_suffix id_t "_lt_trans")
    (DK.Global, DK.Proof DK.Property) goal (fun _ _ -> ());
  Pfedit.by transtactic;
  Lemmas.save_named true

let prove_lt_irrefl indconstr mind body =
  let id_t = body.Declarations.mind_typename in
  let id_lt = add_suffix id_t "_lt" in
  let id_eq = add_suffix id_t "_eq" in
  let x = Nameops.make_ident "x" None in
  let y = Nameops.make_ident "y" None in
  let clt = Libnames.constr_of_reference
    (Nametab.global (Libnames.Ident (dl id_lt))) in
  let ceq = Libnames.constr_of_reference
    (Nametab.global (Libnames.Ident (dl id_eq))) in
  let cfalse = Libnames.constr_of_reference
    (Nametab.global (Libnames.Ident (dl (Names.id_of_string "False")))) in
  let goal =
    mkNamedProd x indconstr
      (mkNamedProd y indconstr
	 (mkArrow
	    (mkApp (clt, [| mkVar x; mkVar y |]))
	    (mkArrow
	       (mkApp (ceq, [| mkVar x; mkVar y |]))
	       (mkApp (cfalse, [| |]))
	    ))) in
  let irrefltactic =
    load_tactic "rinductive_irrefl"
  in
    Lemmas.start_proof (add_suffix id_t "_lt_irrefl")
      (DK.Global, DK.Proof DK.Property) goal (fun _ _ -> ());
    Pfedit.by irrefltactic;
    Lemmas.save_named true

let build_strictorder_ref =
  Libnames.Qualid
    (dl (Libnames.qualid_of_string "Containers.OrderedType.Build_StrictOrder"))
let prove_StrictOrder indconstr mind body =
  prove_lt_trans indconstr mind body;
  prove_lt_irrefl indconstr mind body;
  let id_t = body.Declarations.mind_typename in
  let id_strict = add_suffix id_t "_lt_StrictOrder" in
  let strict =
    CApp (Util.dummy_loc,
	  (None, mkRefC build_strictorder_ref),
	  [hole, None; hole, None; hole, None;
	   mkIdentC (add_suffix id_t "_eq_Equivalence"), None;
	   mkIdentC (add_suffix id_t "_lt_trans"), None;
	   mkIdentC (add_suffix id_t "_lt_irrefl"), None])
  in
    declare_definition id_strict
      (Decl_kinds.Global, false, Decl_kinds.Definition)
      [] None strict None (fun _ _ -> ())


(* proving the [OrderedType] instance *)
let prove_t_compare_spec indconstr mind body =
  let id_t = body.Declarations.mind_typename in
  let id_eq = add_suffix id_t "_eq" in
  let id_lt = add_suffix id_t "_lt" in
  let id_cmp = add_suffix id_t "_cmp" in
  let x = Nameops.make_ident "x" None in
  let y = Nameops.make_ident "y" None in
  let clt = Libnames.constr_of_reference
    (Nametab.global (Libnames.Ident (dl id_lt))) in
  let ceq = Libnames.constr_of_reference
    (Nametab.global (Libnames.Ident (dl id_eq))) in
  let ccmp = Libnames.constr_of_reference
    (Nametab.global (Libnames.Ident (dl id_cmp))) in
  let ccomp_spec = Libnames.constr_of_reference
    (Nametab.global (Libnames.Ident
		       (dl (Names.id_of_string "compare_spec")))) in
  let goal =
    mkNamedProd x indconstr
      (mkNamedProd y indconstr
	 (mkApp (ccomp_spec,
		 [| indconstr; ceq; clt; mkVar x; mkVar y;
		    mkApp (ccmp, [| mkVar x; mkVar y |]) |]))) in
  let spectactic =
    load_tactic_args "rsolve_compare_spec" [add_suffix id_t "_eq_sym"]
  in
  Lemmas.start_proof (add_suffix id_t "_compare_spec")
    (DK.Global, DK.Proof DK.Property) goal (fun _ _ -> ());
  Pfedit.by spectactic;
  Lemmas.save_named true

let build_ot_ref =
  Libnames.Qualid
    (dl (Libnames.qualid_of_string "Containers.OrderedType.Build_OrderedType"))
let prove_OrderedType indconstr mind body =
  prove_t_compare_spec indconstr mind body;
  let id_t = body.Declarations.mind_typename in
  let id_ot = add_suffix id_t "_OrderedType" in
  let ot =
    CApp (Util.dummy_loc,
	  (None, mkRefC build_ot_ref),
	  [hole, None; hole, None; hole, None;
	   mkIdentC (add_suffix id_t "_eq_Equivalence"), None;
	   mkIdentC (add_suffix id_t "_lt_StrictOrder"), None;
	   hole, None;
	   mkIdentC (add_suffix id_t "_compare_spec"), None])
  in
    declare_definition id_ot
      (Decl_kinds.Global, false, Decl_kinds.Definition)
    [] None ot None (fun loc gr ->
		     Typeclasses.declare_instance None (loc=Decl_kinds.Local) gr)
    
let generate_simple_ot gref =
  let gindref = Nametab.global gref in
  let indconstr = Libnames.constr_of_global gindref in
  (* retrieve the inductive type *)
  let (ind, _) =
    Inductive.find_inductive (Global.env ()) indconstr in
  let (mind, ibody) = Global.lookup_inductive ind in
  fprintf std_formatter "%a" print_ind_body ibody;
  (* define the equality predicate *)
  let mutual_eq = make_eq_mutual ind mind ibody in
  (* fprintf std_formatter "%a" print_inductive_def mutual_eq; *)
  Command.do_mutual_inductive mutual_eq true;
  (* define the strict ordering predicate *)
  let mutual_lt = make_lt_mutual ind mind ibody in
  (* fprintf std_formatter "%a" print_inductive_def mutual_lt; *)
  Command.do_mutual_inductive mutual_lt true;
  (* declare the comparison function *)
  let id_cmp, ttt = make_cmp_def ind mind ibody in
    declare_definition id_cmp
      (Decl_kinds.Global, false, Decl_kinds.Definition)
      [] None ttt None (fun _ _ -> ());
  (* prove the Equivalence instance *)
  prove_Equivalence indconstr mind ibody;
  (* prove the StrictOrder instance *)
  prove_StrictOrder indconstr mind ibody;
  (* prove the OrderedType instance *)
  prove_OrderedType indconstr mind ibody

(* for recursive datatypes *)

open Declarations

let print_ind (mind,index) =
  Printf.sprintf "(%s, %d)" (Names.string_of_mind mind) index

let print_recarg = function
  | Norec -> qs "Norec"
  | Mrec ind -> qs (Printf.sprintf "Mrec %s" (print_ind ind))
  | Imbr ind -> qs (Printf.sprintf "Inductive %s" (print_ind ind))

let rec map3 f l1 l2 l3 =
  match l1, l2, l3 with
    | [], [], [] -> []
    | a::q, b::r, c::s -> (f a b c)::(map3 f q r s)
    | _, _, _ ->
	failwith "Invalid_argument [map3] : lists should have the same length"

let req_constr_i eqid cid wp carity cmask =
  let xbar = app_expl_i [] "x" carity in
  let ybar = app_expl_i [] "y" carity in
  let cx = CApp (Util.dummy_loc, (None, mkIdentC cid), xbar) in
  let cy = CApp (Util.dummy_loc, (None, mkIdentC cid), ybar) in
  let rec eq_n_i acc cmask n =
    match n, cmask with
      | 0, [] -> acc
      | n, mask::cmask ->
	  let xn = Nameops.make_ident "x" (Some n) in
	  let yn = Nameops.make_ident "y" (Some n) in
	  let t =
	    if mask then
	      CApp (Util.dummy_loc, (None, mkIdentC eqid),
		    [mkIdentC xn, None; mkIdentC yn, None])
	    else
	      mk_equiv xn yn
	  in
	    eq_n_i
	      (CArrow (Util.dummy_loc, t, acc))
	      cmask
	      (n-1)
      | _, _ -> failwith "Mask does not match arity."
  in
    CProdN (Util.dummy_loc, (prod_n_i [] carity),
	    eq_n_i
	      (CApp (Util.dummy_loc, (None, mkIdentC eqid),
		     [cx, None; cy, None])) (List.rev cmask) carity)

let rmake_eq_mutual ind mask mind body =
  let id_t = body.mind_typename in
  let id_eq = add_suffix id_t "_eq" in
  let wp = body.mind_recargs in
  let lconstr =
    map3 (fun cid carity cmask ->
	    (cf (dl (add_suffix id_eq ("_"^(Names.string_of_id cid))),
		 req_constr_i id_eq cid wp carity cmask)))
      (Array.to_list body.mind_consnames)
      (Array.to_list body.mind_consnrealdecls)
      mask
  in
    [(dl id_eq, [], Some (bin_rel_t id_t) , lconstr), []]

let rlexi_constr eqid ltid cid carity cmask =
  let xbar = app_expl_i [] "x" carity in
  let ybar = app_expl_i [] "y" carity in
  let cx = CApp (Util.dummy_loc, (None, mkIdentC cid), xbar) in
  let cy = CApp (Util.dummy_loc, (None, mkIdentC cid), ybar) in
  let rec one_lexico_case acc n mask = match n, mask with
    | 0, [] -> acc
    | n, mask::masks ->
	let xn = Nameops.make_ident "x" (Some n) in
	let yn = Nameops.make_ident "y" (Some n) in
	let t =
	  if mask then
	    CApp (Util.dummy_loc, (None, mkIdentC eqid),
		  [mkIdentC xn, None; mkIdentC yn, None])
	  else mk_equiv xn yn in
	  one_lexico_case
	    (CArrow (Util.dummy_loc, t, acc)) (n-1) masks
    | _, _ -> failwith "Mask does not match arity."
  in
  let rec all_lexico_cases goal acc n cmask = match n, cmask with
    | 0, [] -> acc
    | n, mask::masks ->
	let xn = Nameops.make_ident "x" (Some n) in
	let yn = Nameops.make_ident "y" (Some n) in
	let t =
	  if mask then
	    CApp (Util.dummy_loc, (None, mkIdentC ltid),
		  [mkIdentC xn, None; mkIdentC yn, None])
	  else mk_lt xn yn in
	let base = CArrow (Util.dummy_loc, t, goal) in
	let c = one_lexico_case base (n-1) masks in
	let name = add_suffix ltid ("_"^(Names.string_of_id cid)^
				      "_"^(string_of_int n)) in
	  all_lexico_cases goal ((name, c)::acc) (n-1) masks
    | _, _ -> failwith "Mask does not match arity."
  in
  let goal =
    CApp (Util.dummy_loc, (None, mkIdentC ltid), [cx, None; cy, None]) in
  let cases =
    all_lexico_cases goal [] carity (List.rev cmask) in
    List.map (fun (name, c) ->
		cf (dl name,
		    CProdN (Util.dummy_loc, (prod_n_i [] carity), c)))
      cases

let rec rlt_constr eqid ltid names arities mask =
  match names, arities, mask with
    | [], [], [] -> []
    | cid::otherids, carity::otherars, cmask::othermasks ->
	let lexi = rlexi_constr eqid ltid cid carity cmask in
	let inter = inter_constr ltid cid carity otherids otherars in
	  lexi@inter@(rlt_constr eqid ltid otherids otherars othermasks)
    | _, _, _ -> failwith "Lists should have the same lengths."

let rmake_lt_mutual ind mask mind body =
  let id_t = body.Declarations.mind_typename in
  let id_lt = add_suffix id_t "_lt" in
  let id_eq = add_suffix id_t "_eq" in
  let names = Array.to_list body.Declarations.mind_consnames in
  let decls = Array.to_list body.Declarations.mind_consnrealdecls in
  let lconstr = rlt_constr id_eq id_lt names decls mask in
    [(dl id_lt, [], Some (bin_rel_t id_t) , lconstr), []]

let mk_cmp_if cmpid x y mask =
  if mask then
    CApp (Util.dummy_loc, (None, mkIdentC cmpid),
	  [mkIdentC x, None; mkIdentC y, None])
  else mk_cmp x y

let rlexi_eqn_constr r cmpid carity cmask =
  let rec branch xs ys cmask =
    match xs, ys, cmask with
      | [], [], [] -> mkIdentC id_Eq
      | [x], [y], [mask] -> mk_cmp_if cmpid x y mask
      | x::xs, y::ys, mask::masks ->
	  let item = [(mk_cmp_if cmpid x y mask, (None, None))] in
	  let brlt =
	    (Util.dummy_loc,
	     [(Util.dummy_loc, [patc ref_Lt []])],
	     mkIdentC id_Lt) in
	  let breq =
	    (Util.dummy_loc,
	     [(Util.dummy_loc, [patc ref_Eq []])],
	     branch xs ys masks) in
	  let brgt =
	    (Util.dummy_loc,
	     [(Util.dummy_loc, [patc ref_Gt []])],
	     mkIdentC id_Gt) in
	    CCases (Util.dummy_loc, RegularStyle, None, item,
		    [brlt; breq; brgt])
      | _, _, _ -> failwith "Lists should have the same size"
  in
  let xbar = lvars [] "x" carity in
  let ybar = lvars [] "y" carity in
    (Util.dummy_loc,
     [(Util.dummy_loc, [patc r (lpats "x" [] carity);
			patc r (lpats "y" [] carity)])],
     branch xbar ybar cmask)

let rec rbranches_constr cmpid names arities mask =
  match names, arities, mask with
    | [], [], [] -> []
    | [cid], [carity], [cmask] ->
	let r = Libnames.Ident (dl cid) in
	let eqn_lexi = rlexi_eqn_constr r cmpid carity cmask in
	  [eqn_lexi]
    | cid::otherids, carity::otherars, cmask::othermasks ->
	let r = Libnames.Ident (dl cid) in
	let eqn_lexi = rlexi_eqn_constr r cmpid carity cmask in
	let eqn_inter1 =
	  (Util.dummy_loc,
	   [(Util.dummy_loc, [patc r (lholes carity); pathole])],
	   mkIdentC id_Lt) in
	let eqn_inter2 =
	  (Util.dummy_loc,
	   [(Util.dummy_loc, [pathole; patc r (lholes carity)])],
	   mkIdentC id_Gt) in
	  eqn_lexi::eqn_inter1::eqn_inter2::
	    (rbranches_constr cmpid otherids otherars othermasks)
    | _, _, _ -> failwith "Lists should have the same lengths."

let rmake_cmp_def ind mask mind body =
  let id_t = body.Declarations.mind_typename in
  let id_cmp = add_suffix id_t "_cmp" in
  let names = Array.to_list body.Declarations.mind_consnames in
  let decls = Array.to_list body.Declarations.mind_consnrealdecls in
  let x = Nameops.make_ident "x" None in
  let y = Nameops.make_ident "y" None in
  let items = [(mkIdentC x, (None, None));
	       (mkIdentC y, (None, None))] in
  let branches = rbranches_constr id_cmp names decls mask in
  let body =  CCases (Util.dummy_loc, RegularStyle, None, items, branches) in
    (dl id_cmp, (None, Topconstr.CStructRec),
     [LocalRawAssum([dl (Names.Name x); dl (Names.Name y)],
		    Default Glob_term.Explicit, mkIdentC id_t)],
     ccomparison,
     Some body)

let make_mask body =
  let wp = body.mind_recargs in
  let f p = Rtree.eq_rtree (=) p wp in
    List.map (List.map f) (Array.to_list (dest_subterms wp))

let generate_rec_ot gref =
  let gindref = Nametab.global gref in
  let indconstr = Libnames.constr_of_global gindref in
    (* retrieve the inductive type *)
  let (ind, _) =
    Inductive.find_rectype (Global.env ()) indconstr in
  let (mind, ibody) = Global.lookup_inductive ind in
    fprintf std_formatter "%a" print_ind_body ibody;
  let pptree = Rtree.pp_tree print_recarg ibody.Declarations.mind_recargs in
    if_verbose Pp.msgnl pptree;
  let mask = make_mask ibody in
    List.iter
      (fun paths ->
	 List.iter (fun b ->
		      fprintf std_formatter "%s "
			(if b then "rec " else "nonrec ")
		   ) paths;
	 fprintf std_formatter "\n"
      ) mask;
  (* define the equality predicate *)
  let mutual_eq = rmake_eq_mutual ind mask mind ibody in
  (*     fprintf std_formatter "%a" print_inductive_def mutual_eq; *)
  Command.do_mutual_inductive mutual_eq true;
  (* define the strict ordering predicate *)
  let mutual_lt = rmake_lt_mutual ind mask mind ibody in
  (*     fprintf std_formatter "%a" print_inductive_def mutual_lt; *)
  Command.do_mutual_inductive mutual_lt true;
  (* declare the comparison function *)
  let fexpr = rmake_cmp_def ind mask mind ibody in
  Command.do_fixpoint [(fexpr, [])];
  (* prove the Equivalence instance *)
  prove_Equivalence indconstr mind ibody;
  (* prove the StrictOrder instance *)
  prove_StrictOrder indconstr mind ibody;
  (* prove the OrderedType instance *)
  prove_OrderedType indconstr mind ibody

open Declarations

let c_of_id id =
  Libnames.constr_of_reference
    (Nametab.global (Libnames.Ident (dl id)))

exception FoundEqual of int
let make_masks mind =
  let roots = Array.map (fun b -> b.mind_recargs) mind.mind_packets in
  let f p =
    try
      Array.iteri (fun i wp ->
		     if Rtree.eq_rtree (=) p wp then raise (FoundEqual i))
	roots;
      (-1)
    with FoundEqual i -> i
  in
  Array.map (fun wp ->
	       List.map (List.map f) (Array.to_list (dest_subterms wp)))
    roots

let meq_constr_i eqid eqids cid carity (cmask : int list) =
  let xbar = app_expl_i [] "x" carity in
  let ybar = app_expl_i [] "y" carity in
  let cx = CApp (Util.dummy_loc, (None, mkIdentC cid), xbar) in
  let cy = CApp (Util.dummy_loc, (None, mkIdentC cid), ybar) in
  let rec eq_n_i acc cmask n =
    match n, cmask with
      | 0, [] -> acc
      | n, mask::cmask ->
	  let xn = Nameops.make_ident "x" (Some n) in
	  let yn = Nameops.make_ident "y" (Some n) in
	  let t =
	    if mask >= 0 then
	      CApp (Util.dummy_loc, (None, mkIdentC eqids.(mask)),
		    [mkIdentC xn, None; mkIdentC yn, None])
	    else
	      mk_equiv xn yn
	  in
	    eq_n_i
	      (CArrow (Util.dummy_loc, t, acc))
	      cmask
	      (n-1)
      | _, _ -> failwith "Mask does not match arity."
  in
    CProdN (Util.dummy_loc, (prod_n_i [] carity),
	    eq_n_i
	      (CApp (Util.dummy_loc, (None, mkIdentC eqid),
		     [cx, None; cy, None])) (List.rev cmask) carity)

let mmake_eq_mutual ind (masks : int list list array) mind =
  let ids = Array.map (fun b -> b.mind_typename) mind.mind_packets in
  let ids_eq = Array.map (fun id -> add_suffix id "_eq") ids in
  let lconstrs =
    Array.mapi
      (fun i body ->
	 let id_eq = ids_eq.(i) in
	 let mask = masks.(i) in
	   map3 (fun cid carity cmask ->
		   (cf (dl (add_suffix id_eq
			      ("_"^(Names.string_of_id cid))),
			meq_constr_i id_eq ids_eq cid carity cmask)))
	     (Array.to_list body.mind_consnames)
	     (Array.to_list body.mind_consnrealdecls)
	     mask)
      mind.mind_packets
  in
    Array.to_list
      (Array.mapi (fun i lconstr ->
		     (dl ids_eq.(i), [], Some (bin_rel_t ids.(i)), lconstr),
		     [])
	 lconstrs)

let mprove_refl k ids ids_eq mind =
  let x = Nameops.make_ident "x" None in
  let ceq i = mkIdentC ids_eq.(i) in
  let goal i =
    CProdN (Util.dummy_loc,
	    [[dl (Names.Name x)],
	     Default Glob_term.Explicit,
	     mkIdentC ids.(i)],
	    mkAppC (ceq i, [mkIdentC x; mkIdentC x])) in
  let goals =
    Array.to_list (Array.mapi
		     (fun i id_eq ->
			(Some (dl (add_suffix id_eq "_refl")),
			 ([], goal i, None))) ids_eq) in
  let refltactic =
    load_tactic (match k with
		   | Simple -> "inductive_refl"
		   | Recursive -> "rinductive_refl"
		   | Mutual -> "minductive_refl")
  in
    Lemmas.start_proof_com (DK.Global, DK.Proof DK.Property)
      goals (fun _ _ -> ());
    for i = 1 to mind.mind_ntypes do
      Pfedit.by refltactic
    done;
    Lemmas.save_named true

let mprove_sym k ids ids_eq mind =
  let x = Nameops.make_ident "x" None in
  let y = Nameops.make_ident "y" None in
  let ceq i = mkIdentC ids_eq.(i) in
  let goal i =
    CProdN (Util.dummy_loc,
	    [[dl (Names.Name x); dl (Names.Name y)],
	     Default Glob_term.Explicit,
	     mkIdentC ids.(i)],
	    CArrow (Util.dummy_loc,
		    mkAppC (ceq i, [mkIdentC x; mkIdentC y]),
		    mkAppC (ceq i, [mkIdentC y; mkIdentC x]))) in
  let goals =
    Array.to_list (Array.mapi
		     (fun i id_eq ->
			(Some (dl (add_suffix id_eq "_sym")),
			 ([], goal i, None))) ids_eq) in
  let symtactic =
    load_tactic (match k with
		   | Simple -> "inductive_sym"
		   | Recursive -> "rinductive_sym"
		   | Mutual -> "minductive_sym")
  in
    Lemmas.start_proof_com (DK.Global, DK.Proof DK.Property)
      goals (fun _ _ -> ());
    for i = 1 to mind.mind_ntypes do
      Pfedit.by symtactic
    done;
    Lemmas.save_named true

let mprove_trans k ids ids_eq mind =
  let x = Nameops.make_ident "x" None in
  let y = Nameops.make_ident "y" None in
  let z = Nameops.make_ident "z" None in
  let ceq i = mkIdentC ids_eq.(i) in
  let goal i =
    CProdN (Util.dummy_loc,
	    [[dl (Names.Name x); dl (Names.Name y); dl (Names.Name z)],
	     Default Glob_term.Explicit,
	     mkIdentC ids.(i)],
	    CArrow (Util.dummy_loc,
		    mkAppC (ceq i, [mkIdentC x; mkIdentC y]),
		    CArrow (Util.dummy_loc,
			    mkAppC (ceq i, [mkIdentC y; mkIdentC z]),
			    mkAppC (ceq i, [mkIdentC x; mkIdentC z])))) in
  let goals =
    Array.to_list (Array.mapi
		     (fun i id_eq ->
			(Some (dl (add_suffix id_eq "_trans")),
			 ([], goal i, None))) ids_eq) in
  let transtactic =
    load_tactic (match k with
		   | Simple -> "inductive_trans"
		   | Recursive -> "rinductive_trans"
		   | Mutual -> "minductive_trans")
  in
    Lemmas.start_proof_com (DK.Global, DK.Proof DK.Property)
      goals (fun _ _ -> ());
    for i = 1 to mind.mind_ntypes do
      Pfedit.by transtactic
    done;
    Lemmas.save_named true

let mprove_Equivalence k mind =
  let ids = Array.map (fun body -> body.mind_typename) mind.mind_packets in
  let ids_eq = Array.map (fun id_t -> add_suffix id_t "_eq") ids in
  let ids_equiv = Array.map (fun id -> add_suffix id "_Equivalence") ids_eq in
    mprove_refl k ids ids_eq mind;
    mprove_sym k ids ids_eq mind;
    mprove_trans k ids ids_eq mind;
  let equiv i =
    CApp (Util.dummy_loc,
	  (None, mkIdentC (Names.id_of_string "Build_Equivalence")),
	  [hole, None; hole, None;
	   mkIdentC (add_suffix ids.(i) "_eq_refl"), None;
	   mkIdentC (add_suffix ids.(i) "_eq_sym"), None;
	   mkIdentC (add_suffix ids.(i) "_eq_trans"), None])
  in
    Array.iteri (fun i id_equiv ->
		   declare_definition id_equiv
		     (Decl_kinds.Global, false, Decl_kinds.Definition)
		     [] None (equiv i) None (fun _ _ -> ()))
      ids_equiv

let mlexi_constr ids_eq ids_lt ltid cid carity cmask =
  let xbar = app_expl_i [] "x" carity in
  let ybar = app_expl_i [] "y" carity in
  let cx = CApp (Util.dummy_loc, (None, mkIdentC cid), xbar) in
  let cy = CApp (Util.dummy_loc, (None, mkIdentC cid), ybar) in
  let rec one_lexico_case acc n mask = match n, mask with
    | 0, [] -> acc
    | n, mask::masks ->
	let xn = Nameops.make_ident "x" (Some n) in
	let yn = Nameops.make_ident "y" (Some n) in
	let t =
	  if mask >= 0 then
	    CApp (Util.dummy_loc, (None, mkIdentC ids_eq.(mask)),
		  [mkIdentC xn, None; mkIdentC yn, None])
	  else mk_equiv xn yn in
	  one_lexico_case
	    (CArrow (Util.dummy_loc, t, acc)) (n-1) masks
    | _, _ -> failwith "Mask does not match arity."
  in
  let rec all_lexico_cases goal acc n cmask = match n, cmask with
    | 0, [] -> acc
    | n, mask::masks ->
	let xn = Nameops.make_ident "x" (Some n) in
	let yn = Nameops.make_ident "y" (Some n) in
	let t =
	  if mask >= 0 then
	    CApp (Util.dummy_loc, (None, mkIdentC ids_lt.(mask)),
		  [mkIdentC xn, None; mkIdentC yn, None])
	  else mk_lt xn yn in
	let base = CArrow (Util.dummy_loc, t, goal) in
	let c = one_lexico_case base (n-1) masks in
	let name = add_suffix ltid ("_"^(Names.string_of_id cid)^
				      "_"^(string_of_int n)) in
	  all_lexico_cases goal ((name, c)::acc) (n-1) masks
    | _, _ -> failwith "Mask does not match arity."
  in
  let goal =
    CApp (Util.dummy_loc, (None, mkIdentC ltid), [cx, None; cy, None]) in
  let cases =
    all_lexico_cases goal [] carity (List.rev cmask) in
    List.map (fun (name, c) ->
		cf (dl name,
		    CProdN (Util.dummy_loc, (prod_n_i [] carity), c)))
      cases

let rec mlt_constr ids_eq ids_lt ltid names arities mask =
  match names, arities, mask with
    | [], [], [] -> []
    | cid::otherids, carity::otherars, cmask::othermasks ->
	let lexi = mlexi_constr ids_eq ids_lt ltid cid carity cmask in
	let inter = inter_constr ltid cid carity otherids otherars in
	  lexi@inter@(mlt_constr ids_eq ids_lt ltid
			otherids otherars othermasks)
    | _, _, _ -> failwith "Lists should have the same lengths."

let mmake_lt_mutual ind masks mind =
  let ids = Array.map (fun body -> body.mind_typename) mind.mind_packets in
  let ids_lt = Array.map (fun id_t -> add_suffix id_t "_lt") ids in
  let ids_eq = Array.map (fun id_t -> add_suffix id_t "_eq") ids in
  let lconstrs =
    Array.mapi (fun i body ->
		  let names = Array.to_list body.mind_consnames in
		  let decls = Array.to_list body.mind_consnrealdecls in
		  mlt_constr ids_eq ids_lt ids_lt.(i) names decls masks.(i))
      mind.mind_packets
  in
  Array.to_list
    (Array.mapi (fun i lconstr ->
		   (dl ids_lt.(i), [], Some (bin_rel_t ids.(i)), lconstr),
		   [])
       lconstrs)

(* proving that the ordering is a [StrictOrder] *)
open Tacexpr
open Genarg

let apply_tactic s tacs =
  Tacexpr.TacArg
    (Util.dummy_loc, Tacexpr.TacCall (Util.dummy_loc,
		      Libnames.Ident (dl (Names.id_of_string s)),
		      List.map (fun t -> Tacexpr.Tacexp t) tacs))

let seq_eapply lids : raw_tactic_expr =
  let b = Nameops.make_ident "__B" None in
  let apply id =
    TacAtom (Util.dummy_loc,
	     TacApply (true, false,
		       [(mkIdentC id,
			 Glob_term.ImplicitBindings [mkIdentC b])],
		       None))
  in
    TacFun ([Some b], TacFirst (List.map apply lids))

let seq_eapply_sym lids lsyms : raw_tactic_expr =
  let b = Nameops.make_ident "__B" None in
  let apply_with_sym id idsym =
    TacThens(
      TacAtom (Util.dummy_loc,
	       TacApply (true, false,
			 [(mkIdentC id,
			   Glob_term.ImplicitBindings [mkIdentC b])],
			 None)),
      [
	TacAtom (Util.dummy_loc,
		 TacApply (true, false,
			   [(mkIdentC idsym, Glob_term.NoBindings)],
			   None));
	TacId []
      ])
  in
    TacFun ([Some b], TacFirst (List.map2 apply_with_sym lids lsyms))


let mprove_lt_trans k ids ids_eq ids_lt mind =
  let x = Nameops.make_ident "x" None in
  let y = Nameops.make_ident "y" None in
  let z = Nameops.make_ident "z" None in
  let clt i = mkIdentC ids_lt.(i) in
  let ceq i = mkIdentC ids_eq.(i) in
  let solve_arg : raw_tactic_expr =
    let lems =
      Array.fold_left
	(fun acc id_eq ->
	   ((),mkIdentC (add_suffix id_eq "_sym"))::
	     ((),mkIdentC (add_suffix id_eq "_trans"))::acc
	) [] ids_eq in
      TacAtom (Util.dummy_loc,
	       TacExtend (Util.dummy_loc, "eauto",
			  [in_gen (wit_opt rawwit_int_or_var) None;
			   in_gen (wit_opt rawwit_int_or_var) None;
			   in_gen Eauto.rawwit_auto_using lems;
			   in_gen Eauto.rawwit_hintbases (Some [])]))
  in
  let prove_eq_lt_and_gt () =
    let lemma_eq_lt i =
      CProdN (Util.dummy_loc,
	      [[dl (Names.Name x); dl (Names.Name y); dl (Names.Name z)],
	       Default Glob_term.Explicit,
	       mkIdentC ids.(i)],
	      CArrow (Util.dummy_loc,
		      mkAppC (ceq i, [mkIdentC x; mkIdentC y]),
		      CArrow (Util.dummy_loc,
			      mkAppC (clt i, [mkIdentC x; mkIdentC z]),
			      mkAppC (clt i, [mkIdentC y; mkIdentC z])))) in
    let lemma_eq_gt i =
      CProdN (Util.dummy_loc,
	      [[dl (Names.Name x); dl (Names.Name y); dl (Names.Name z)],
	       Default Glob_term.Explicit,
	       mkIdentC ids.(i)],
	      CArrow (Util.dummy_loc,
		      mkAppC (ceq i, [mkIdentC x; mkIdentC y]),
		      CArrow (Util.dummy_loc,
			      mkAppC (clt i, [mkIdentC z; mkIdentC x]),
			      mkAppC (clt i, [mkIdentC z; mkIdentC y])))) in
    let lemmas_eq_lt =
      Array.to_list (Array.mapi
		       (fun i id ->
			  (Some (dl (add_suffix id "_lt")),
			   ([], lemma_eq_lt i, None))) ids_eq) in
    let eqlttactic =
      Tacinterp.interp (apply_tactic "minductive_eq_lt_gt"
			  [apply_tactic "msolve_eq_lt" [solve_arg]]) in
    let lemmas_eq_gt =
      Array.to_list (Array.mapi
		       (fun i id ->
			  (Some (dl (add_suffix id "_gt")),
			   ([], lemma_eq_gt i, None))) ids_eq) in
    let eqgttactic =
      Tacinterp.interp (apply_tactic "minductive_eq_lt_gt"
			  [apply_tactic "msolve_eq_gt" [solve_arg]])
    in
    Lemmas.start_proof_com (DK.Global, DK.Proof DK.Property)
      lemmas_eq_lt (fun _ _ -> ());
      for i = 1 to mind.mind_ntypes do
	Pfedit.by eqlttactic;
      done;
      Lemmas.save_named true;
    Lemmas.start_proof_com (DK.Global, DK.Proof DK.Property)
      lemmas_eq_gt (fun _ _ -> ());
    for i = 1 to mind.mind_ntypes do
      Pfedit.by eqgttactic
    done;
    Lemmas.save_named true
  in
  let goal i =
    CProdN (Util.dummy_loc,
	    [[dl (Names.Name x); dl (Names.Name y); dl (Names.Name z)],
	     Default Glob_term.Explicit,
	     mkIdentC ids.(i)],
	    CArrow (Util.dummy_loc,
		    mkAppC (clt i, [mkIdentC x; mkIdentC y]),
		    CArrow (Util.dummy_loc,
			    mkAppC (clt i, [mkIdentC y; mkIdentC z]),
			    mkAppC (clt i, [mkIdentC x; mkIdentC z])))) in
  let goals =
    Array.to_list (Array.mapi
		     (fun i id_lt ->
			(Some (dl (add_suffix id_lt "_trans")),
			 ([], goal i, None))) ids_lt) in
  let transtactic =
    match k with
      | Simple -> load_tactic "inductive_lexico_trans"
      | Recursive ->
	  load_tactic_args "rinductive_lexico_trans"
	    [add_suffix ids_eq.(0) "_sym"; add_suffix ids_eq.(0) "_trans";
	     add_suffix ids_eq.(0) "_gt"; add_suffix ids_eq.(0) "_lt"]
      | _ ->
	  let leq = Array.to_list ids_eq in
	  let strans = seq_eapply
	    (List.map (fun id -> add_suffix id "_trans") leq) in
	  let seqgt = seq_eapply
	    (List.map (fun id -> add_suffix id "_gt") leq) in
	  let seqlt = seq_eapply_sym
	    (List.map (fun id -> add_suffix id "_lt") leq)
	    (List.map (fun id -> add_suffix id "_sym") leq) in
	  Tacinterp.interp (apply_tactic "minductive_lexico_trans"
			      [strans; seqgt; seqlt])
  in
  if k = Simple then () else prove_eq_lt_and_gt ();
  Lemmas.start_proof_com (DK.Global, DK.Proof DK.Property)
    goals (fun _ _ -> ());
  for i = 1 to mind.mind_ntypes do
    Pfedit.by transtactic
  done;
  Lemmas.save_named true

let mprove_lt_irrefl k ids ids_eq ids_lt mind =
  let x = Nameops.make_ident "x" None in
  let y = Nameops.make_ident "y" None in
  let clt i = mkIdentC ids_lt.(i) in
  let ceq i = mkIdentC ids_eq.(i) in
  let cfalse = mkIdentC (Names.id_of_string "False") in
  let goal i =
    CProdN (Util.dummy_loc,
	    [[dl (Names.Name x); dl (Names.Name y)],
	     Default Glob_term.Explicit,
	     mkIdentC ids.(i)],
	    CArrow (Util.dummy_loc,
		    mkAppC (clt i, [mkIdentC x; mkIdentC y]),
		    CArrow (Util.dummy_loc,
			    mkAppC (ceq i, [mkIdentC x; mkIdentC y]),
			    cfalse))) in
  let goals =
    Array.to_list (Array.mapi
		     (fun i id ->
			(Some (dl (add_suffix id "_irrefl")),
			 ([], goal i, None))) ids_lt) in
  let irrefltactic =
    load_tactic (if k = Simple then "inductive_irrefl"
		 else "minductive_irrefl")
  in
  Lemmas.start_proof_com (DK.Global, DK.Proof DK.Property)
    goals (fun _ _ -> ());
  for i = 1 to mind.mind_ntypes do
    Pfedit.by irrefltactic
  done;
  Lemmas.save_named true

let mprove_StrictOrder k mind =
  let ids = Array.map (fun body -> body.mind_typename) mind.mind_packets in
  let ids_eq = Array.map (fun id_t -> add_suffix id_t "_eq") ids in
  let ids_lt = Array.map (fun id_t -> add_suffix id_t "_lt") ids in
  let ids_equiv = Array.map (fun id -> add_suffix id "_Equivalence") ids_eq in
  let ids_order = Array.map (fun id -> add_suffix id "_StrictOrder") ids_lt in
  mprove_lt_irrefl k ids ids_eq ids_lt mind;
  mprove_lt_trans k ids ids_eq ids_lt mind;
  let strict i =
    CApp (Util.dummy_loc,
	  (None, mkRefC build_strictorder_ref),
	  [hole, None; hole, None; hole, None;
	   mkIdentC ids_equiv.(i), None;
	   mkIdentC (add_suffix ids_lt.(i) "_trans"), None;
	   mkIdentC (add_suffix ids_lt.(i) "_irrefl"), None])
  in
  Array.iteri (fun i id_order ->
		 declare_definition id_order
		   (Decl_kinds.Global, false, Decl_kinds.Definition)
		   [] None (strict i) None (fun _ _ -> ()))
    ids_order

let mmk_cmp_if ids_cmp x y mask =
  if mask >= 0 then
    CApp (Util.dummy_loc, (None, mkIdentC ids_cmp.(mask)),
	  [mkIdentC x, None; mkIdentC y, None])
  else mk_cmp x y

let mlexi_eqn_constr r ids_cmp carity cmask =
  let rec branch xs ys cmask =
    match xs, ys, cmask with
      | [], [], [] -> mkIdentC id_Eq
      | [x], [y], [mask] -> mmk_cmp_if ids_cmp x y mask
      | x::xs, y::ys, mask::masks ->
	  let item = [(mmk_cmp_if ids_cmp x y mask, (None, None))] in
	  let brlt =
	    (Util.dummy_loc,
	     [(Util.dummy_loc, [patc ref_Lt []])],
	     mkIdentC id_Lt) in
	  let breq =
	    (Util.dummy_loc,
	     [(Util.dummy_loc, [patc ref_Eq []])],
	     branch xs ys masks) in
	  let brgt =
	    (Util.dummy_loc,
	     [(Util.dummy_loc, [patc ref_Gt []])],
	     mkIdentC id_Gt) in
	    CCases (Util.dummy_loc, RegularStyle, None, item,
		    [brlt; breq; brgt])
      | _, _, _ -> failwith "Lists should have the same size"
  in
  let xbar = lvars [] "x" carity in
  let ybar = lvars [] "y" carity in
    (Util.dummy_loc,
     [(Util.dummy_loc, [patc r (lpats "x" [] carity);
			patc r (lpats "y" [] carity)])],
     branch xbar ybar cmask)

let rec mbranches_constr ids_cmp names arities mask =
  match names, arities, mask with
    | [], [], [] -> []
    | [cid], [carity], [cmask] ->
	let r = Libnames.Ident (dl cid) in
	let eqn_lexi = mlexi_eqn_constr r ids_cmp carity cmask in
	  [eqn_lexi]
    | cid::otherids, carity::otherars, cmask::othermasks ->
	let r = Libnames.Ident (dl cid) in
	let eqn_lexi = mlexi_eqn_constr r ids_cmp carity cmask in
	let eqn_inter1 =
	  (Util.dummy_loc,
	   [(Util.dummy_loc, [patc r (lholes carity); pathole])],
	   mkIdentC id_Lt) in
	let eqn_inter2 =
	  (Util.dummy_loc,
	   [(Util.dummy_loc, [pathole; patc r (lholes carity)])],
	   mkIdentC id_Gt) in
	  eqn_lexi::eqn_inter1::eqn_inter2::
	    (mbranches_constr ids_cmp otherids otherars othermasks)
    | _, _, _ -> failwith "Lists should have the same lengths."

let mmake_cmp_def k ind masks mind =
  let ids = Array.map (fun body -> body.mind_typename) mind.mind_packets in
  let ids_cmp = Array.map (fun id_t -> add_suffix id_t "_cmp") ids in
  let x = Nameops.make_ident "x" None in
  let y = Nameops.make_ident "y" None in
  let make_body i body =
    let names = Array.to_list body.Declarations.mind_consnames in
    let decls = Array.to_list body.Declarations.mind_consnrealdecls in
    let items = [(mkIdentC x, (None, None));
		 (mkIdentC y, (None, None))] in
    let branches = mbranches_constr ids_cmp names decls masks.(i) in
    CCases (Util.dummy_loc, RegularStyle, None, items, branches)
  in
  let make_block i body =
    (dl ids_cmp.(i), (None, Topconstr.CStructRec),
     [LocalRawAssum([dl (Names.Name x); dl (Names.Name y)],
		    Default Glob_term.Explicit, mkIdentC ids.(i))],
     ccomparison,
     Some (make_body i body))
  in
  match k with
    | Simple ->
	let def =
	  CLambdaN (Util.dummy_loc,
		    [([dl (Names.Name x); dl (Names.Name y)],
		      Default Glob_term.Explicit,
		      mkIdentC ids.(0))],
		    make_body 0 mind.mind_packets.(0))
	in
	  declare_definition ids_cmp.(0)
	    (Decl_kinds.Global, false, Decl_kinds.Definition)
	    [] None def None (fun _ _ -> ())
    | Recursive | Mutual ->
	let defs =
	  Array.to_list (Array.mapi
			   (fun i body -> make_block i body, [])
			   mind.mind_packets)
	in
	Command.do_fixpoint defs

(* proving the [OrderedType] instance *)
let mprove_compare_spec k ids mind =
  let ids_eq = Array.map (fun id_t -> add_suffix id_t "_eq") ids in
  let ids_lt = Array.map (fun id_t -> add_suffix id_t "_lt") ids in
  let ids_cmp = Array.map (fun id_t -> add_suffix id_t "_cmp") ids in
  let ids_sym = Array.map (fun id_t -> add_suffix id_t "_sym") ids_eq in
  let x = Nameops.make_ident "x" None in
  let y = Nameops.make_ident "y" None in
  let clt i = mkIdentC (ids_lt.(i)) in
  let ceq i = mkIdentC (ids_eq.(i)) in
  let ccmp i = mkIdentC (ids_cmp.(i)) in
  let ccomp_spec = mkIdentC (Names.id_of_string "compare_spec") in
  let goal i =
    CProdN (Util.dummy_loc,
	    [[dl (Names.Name x); dl (Names.Name y)],
	     Default Glob_term.Explicit,
	     mkIdentC ids.(i)],
	    mkAppC (ccomp_spec,
		    [ ceq i; clt i;
		      mkIdentC x; mkIdentC y;
		      (mkAppC (ccmp i, [ mkIdentC x; mkIdentC y ]))]))
  in
  let goals =
    Array.to_list (Array.mapi
		     (fun i id ->
			(Some (dl (add_suffix id "_compare_spec")),
			 ([], goal i, None))) ids) in
  let using_sym : raw_tactic_expr =
    TacAtom (Util.dummy_loc,
	     TacAuto (Tacexpr.Off, None,
		      List.map mkIdentC (Array.to_list ids_sym), Some [])) in
  let comparespectactic = match k with
    | Simple -> load_tactic "solve_compare_spec"
    | Recursive ->
	load_tactic_args "rsolve_compare_spec" [ids_sym.(0)]
    | Mutual ->
	Tacinterp.interp (apply_tactic "msolve_compare_spec" [using_sym])
  in
  Lemmas.start_proof_com (DK.Global, DK.Proof DK.Property)
    goals (fun _ _ -> ());
  for i = 1 to mind.mind_ntypes do
    Pfedit.by comparespectactic
  done;
  Lemmas.save_named true

let mprove_OrderedType k mind =
  let ids = Array.map (fun body -> body.mind_typename) mind.mind_packets in
  mprove_compare_spec k ids mind;
  let prove_ot i body =
    let id_ot = add_suffix ids.(i) "_OrderedType" in
    let ot =
      CApp (Util.dummy_loc,
	    (None, mkRefC build_ot_ref),
	    [hole, None; hole, None; hole, None;
	     mkIdentC (add_suffix ids.(i) "_eq_Equivalence"), None;
	     mkIdentC (add_suffix ids.(i) "_lt_StrictOrder"), None;
	     hole, None;
	     mkIdentC (add_suffix ids.(i) "_compare_spec"), None])
    in
      declare_definition id_ot
	(Decl_kinds.Global, false, Decl_kinds.Definition)
	[] None ot None (fun _ gr -> 
			 Typeclasses.declare_instance None false gr)
  in
  Array.iteri prove_ot mind.mind_packets

let generate_mutual_ot gref =
  Coqlib.check_required_library ["Coq";"Classes";"Equivalence"];
  Coqlib.check_required_library ["Containers";"Tactics"];
  let gindref = Nametab.global gref in
  let indconstr = Libnames.constr_of_global gindref in
  (* retrieve the inductive type *)
  let (ind, _) =
    Inductive.find_rectype (Global.env ()) indconstr in
  let (mind, _) = Global.lookup_inductive ind in
  let masks = make_masks mind in
  Array.iteri (fun i mask ->
		 fprintf std_formatter "Mask %d :\n" i;
		 List.iter
		   (fun paths ->
		      List.iter (fun b -> fprintf std_formatter "%d " b)
			paths;
		      fprintf std_formatter "\n"
		   ) mask) masks;
  let kind =
    if mind.mind_ntypes > 1 then Mutual
    else
      if List.for_all (List.for_all (fun b -> b = -1)) masks.(0) then
	Simple
      else
	Recursive
  in
  if_verbose Pp.msgnl (str "Inductive kind : " ++ pr_kind kind);
  (* define the equality predicate *)
  let mutual_eq = mmake_eq_mutual ind masks mind in
  Command.do_mutual_inductive mutual_eq true;
  (* prove the Equivalence instance *)
  mprove_Equivalence kind mind;
  (* define the strict ordering predicate *)
  let mutual_lt = mmake_lt_mutual ind masks mind in
  Command.do_mutual_inductive mutual_lt true;
  (* prove the StrictOrder instance *)
  mprove_StrictOrder kind mind;
  (* define the comparison function *)
  mmake_cmp_def kind ind masks mind;
  (* provide the OrderedType instance *)
  mprove_OrderedType kind mind

let generate_ot = generate_mutual_ot

let generate_scheme gref =
  let gindref = Nametab.global gref in
  let indconstr = Libnames.constr_of_global gindref in
    (* retrieve the inductive type *)
  let (ind, _) =
    Inductive.find_rectype (Global.env ()) indconstr in
  let (mind, _) = Global.lookup_inductive ind in
  let rec lnames acc = function
    | 0 -> acc
    | n ->
	let name = (mind.mind_packets.(n-1)).mind_typename in
	  lnames (name::acc) (n-1)
  in
  let names = lnames [] mind.mind_ntypes in
  let schemes =
    List.map (fun id ->
		let id' = dl (add_suffix id "_mutual_ind") in
		  (Some id',
		   Vernacexpr.InductionScheme(true, (* dependent *)
					      Genarg.AN
						(Libnames.Ident (dl id)),
					      Glob_term.GProp Term.Null))
	     ) names
  in
  Indschemes.do_scheme schemes

let print_paths gref =
  let ind = Nametab.global_inductive gref in
  let (mind, ibody) = Global.lookup_inductive ind in
    if_verbose Pp.msgnl
      (str "Params :" ++ (int mind.mind_nparams));
    if_verbose Pp.msgnl
      (str "Recursively uniform params :" ++ (int mind.mind_nparams_rec));
    if_verbose Pp.msgnl
      (str "Real arguments :" ++ (int ibody.mind_nrealargs));
  Array.iteri
    (fun i body ->
       let id = Names.string_of_id body.mind_typename in
       let pptree =
	 Rtree.pp_tree print_recarg body.mind_recargs in
	 if_verbose Pp.msgnl (str id);
	 if_verbose Pp.msgnl pptree)
    mind.mind_packets

(* Syntax extensions *)

(* The 3 next commands are for debug *)
VERNAC COMMAND EXTEND GenerateSimpleOrderedType
 ["Generate" "Simple" "OrderedType" global(indref)] ->
  [ generate_simple_ot indref ]
    END

VERNAC COMMAND EXTEND GenerateRecursiveOrderedType
 ["Generate" "Recursive" "OrderedType" global(indref)] ->
  [ generate_rec_ot indref ]
END

VERNAC COMMAND EXTEND GenerateMutualOrderedType
 ["Generate" "Mutual" "OrderedType" global(indref)] ->
  [ generate_mutual_ot indref ]
END
(* *)

VERNAC COMMAND EXTEND GenerateOrderedType
 ["Generate" "OrderedType" global(indref)] ->
  [ generate_ot indref ]
END

VERNAC COMMAND EXTEND GenerateScheme
 ["Generate" "Scheme" global(indref)] ->
   [ generate_scheme indref ]
END

VERNAC COMMAND EXTEND PrintWPaths
 ["Print" "Paths" global(indref)] ->
   [ print_paths indref ]
END
