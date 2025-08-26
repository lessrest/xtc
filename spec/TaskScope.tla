----------------------------- MODULE TaskScope -----------------------------
EXTENDS FiniteSets, Sequences, Naturals

(***************************************************************************)
(* TaskScope: Concrete Implementation of Hierarchical Task Shutdown       *)
(*                                                                         *)
(* This specification implements the abstract task tree model with        *)
(* practical shutdown coordination mechanisms. While AbstractTaskTree     *)
(* defines what leaf-first reaping should look like, TaskScope shows how  *)
(* to achieve it in a concurrent system where tasks continue spawning     *)
(* during shutdown operations.                                             *)
(*                                                                         *)
(* Key mechanisms:                                                         *)
(* - Mark captures a subtree snapshot for orderly teardown       *)
(* - Closing tracks progress through the shutdown sequence                 *)
(* - Birth operations are prevented in subtrees undergoing shutdown       *)
(*                                                                         *)
(* The specification demonstrates how snapshot-based approaches can        *)
(* transform complex dynamic coordination problems into simpler static     *)
(* ordering constraints.                                                   *)
(*                                                                         *)
(* Variables:                                                              *)
(* - Live     : currently running tasks                                   *)
(* - Eggs     : available task identifiers (not yet spawned)              *)
(* - parent   : parent mapping (roots self-parented)                      *)
(* - births   : log of task creation events                               *)
(* - deaths   : log of task termination events (leaf-first order)         *)
(* - closing  : tasks currently being shut down, per shutdown operation   *)
(* - snapshot : snapshot of subtree when shutdown began, per operation     *)
(* - linksnap : the parent of each task in the snapshot, per operation     *)
(* - depth    : current depth of each live task in the hierarchy          *)
(***************************************************************************)

CONSTANTS PID
VARIABLES Live, Eggs, parent, births, deaths,
          closing, snapshot, linksnap, depth

ℕ ≜ Nat

\* Sentinel value for tasks that have no parent (cleared on death).
None ≜ "none"

\* All state variables bundled for convenience.
vars ≜ ⟨ Live, Eggs, parent, births, deaths,
         closing, snapshot, linksnap, depth ⟩

(***************************************************************************)
(* Initialization                                                          *)
(* Start with one root task, empty logs, and no active shutdowns.         *)
(***************************************************************************)

Init ≜
  ∃ root ∈ PID :
    ∧ Live      = { root }
    ∧ Eggs      = PID \ { root }
    ∧ parent    = [[p ∈ PID ↦ None] EXCEPT ![root] = root]
    ∧ births    = ⟨ ⟩
    ∧ deaths    = ⟨ ⟩
    ∧ closing   = [p ∈ PID ↦ {}]
    ∧ snapshot  = [p ∈ PID ↦ {}]
    ∧ linksnap  = [p ∈ PID ↦ [q ∈ PID ↦ {}]]
    ∧ depth     = [p ∈ PID ↦ 0]

(***************************************************************************)
(* Helpers                                                                 *)
(* Functions to navigate the task tree structure and shutdown state.      *)
(***************************************************************************)

\* Root tasks are self-parented.
Roots       ≜ { p ∈ Live : parent[p] = p }
\* Children are live tasks with this parent (excluding self-reference).
Children(p) ≜ { q ∈ Live : parent[q] = p ∧ q ≠ p }

\* Recursively find all descendants in the live tree.
RECURSIVE Descendants(_)
Descendants(p) ≜ Children(p) ∪ UNION { Descendants(c) : c ∈ Children(p) }

\* Was u an ancestor of v in the snapshot?
WasAncestor(r, u, v) ==
  u # v /\ v ∈ linksnap[r][u]

\* Complete subtree including the root node itself.
Subtree(p) ≜ {p} ∪ Descendants(p)

\* Check if x is a leaf within the closing set r - it has no children
\* that are also in the closing set (meaning it can be safely reaped).
Leaf(r, x) ≜
  ∧ x ∈ closing[r]
  ∧ ∀ y ∈ closing[r] : parent[y] ≠ x

\* Extract from the deaths log only those tasks that were part of
\* shutdown r's original snapshot.
DeathsFor(r) ≜ SelectSeq(deaths, LAMBDA x : x ∈ snapshot[r])

\* Check if two sets have no elements in common.
DisjointSets(A, B) ≜ A ∩ B = {}

\* The set of all tasks that are currently being shut down.
GlobalClosingSet ≜ UNION { closing[r] : r ∈ PID }

\* Spawn a new task as a child of an existing parent.
Make(mom, kid) ≜
  ∧ kid ∈ Eggs
  ∧ mom ∈ Live
  ∧ mom ∉ GlobalClosingSet
  ∧ Live'   = Live ∪ {kid}
  ∧ Eggs'   = Eggs \ {kid}
  ∧ parent' = [parent EXCEPT ![kid] = mom]
  ∧ depth'  = [depth  EXCEPT ![kid] = depth[mom] + 1]
  ∧ births' = births ∘ ⟨kid⟩
  ∧ UNCHANGED ⟨ deaths, closing, snapshot, linksnap ⟩

\* Begin shutdown process for a subtree rooted at node.
Mark(node) ≜
  ∧ node ∈ Live
  ∧ node ∉ Roots
  ∧ LET Snapshot ≜ Subtree(node) IN
      ∧ DisjointSets(Snapshot, GlobalClosingSet)
      ∧ closing'   = [closing   EXCEPT ![node] = Snapshot]
      ∧ snapshot'  = [snapshot  EXCEPT ![node] = Snapshot]
      ∧ linksnap'  = [linksnap  EXCEPT ![node] = [q ∈ PID ↦ Descendants(q)]]
      ∧ UNCHANGED ⟨ Live, Eggs, parent, births, deaths, depth ⟩

\* Remove one leaf task from an active shutdown operation.
Reap(root, leaf) ≜
  ∧ leaf ∈ Live
  ∧ Leaf(root, leaf)
  ∧ Live'    = Live \ {leaf}
  ∧ parent'  = [parent  EXCEPT ![leaf] = None]
  ∧ depth'   = [depth   EXCEPT ![leaf] = 0]
  ∧ closing' = [closing EXCEPT ![root] = closing[root] \ {leaf}]
  ∧ deaths'  = deaths ∘ ⟨leaf⟩
  ∧ UNCHANGED ⟨ births, snapshot, linksnap, Eggs ⟩

Next ≜
   ∨ ∃ mom, kid ∈ PID    : Make(mom, kid)
   ∨ ∃ node ∈ PID        : Mark(node)
   ∨ ∃ root, leaf ∈ PID  : Reap(root, leaf)

\* Complete specification with fairness constraint to ensure shutdowns complete.
Spec ≜
  Init ∧ □[Next]_vars
  ∧ WF_vars(∃ root, leaf ∈ PID : Reap(root, leaf))

(***************************************************************************)
(* Safety Invariants                                                       *)
(* Properties that must hold in every reachable state.                    *)
(***************************************************************************)

\* Basic type safety and domain constraints.
TypeInv ≜
  ∧ Live ⊆ PID
  ∧ Eggs ⊆ PID
  ∧ Live ∩ Eggs = {}
  ∧ parent    ∈ [PID → PID ∪ {None}]
  ∧ births    ∈ Seq(PID)
  ∧ deaths    ∈ Seq(PID)
  ∧ closing   ∈ [PID → SUBSET PID]
  ∧ snapshot  ∈ [PID → SUBSET PID]
  ∧ linksnap  ∈ [PID → [PID → SUBSET PID]]
  ∧ depth     ∈ [PID → ℕ]
  ∧ ∀ r ∈ PID : closing[r] ⊆ Live

\* System maintains exactly one root task at all times.
SingleRoot ≜
  Cardinality({ pid ∈ Live : parent[pid] = pid }) = 1

\* No orphaned tasks: every non-root has a live parent.
NoOrphans ≜
  ∀ kid ∈ Live \ Roots : parent[kid] ∈ Live

\* Concurrent shutdowns don't interfere with each other.
DisjointClosings ≜
  ∀ r1, r2 ∈ PID : r1 ≠ r2 ⇒ closing[r1] ∩ closing[r2] = {}

\* Depth tracking is consistent with the parent-child relationships.
DepthInvariant ≜
  ∀ pid ∈ Live :
    IF   parent[pid] = pid
    THEN depth[pid] = 0
    ELSE depth[pid] = depth[parent[pid]] + 1

\* Find the index of an element in a sequence.
Index(seq, x) ≜ CHOOSE i ∈ 1‥Len(seq) : seq[i] = x

\* Find the index of an element in the death sequence
\* for a given shutdown operation.
DeathOrder(r, x) ≜
  Index(DeathsFor(r), x)

\* Deaths must be in post-order for each shutdown operation.
PostOrderDeaths ≜
  ∀ r ∈ PID :
    (snapshot[r] ≠ {} ∧ closing[r] = {})
    =>  ∀ u, v ∈ snapshot[r] :
      WasAncestor(r, u, v) ⇒
        DeathOrder(r, u) > DeathOrder(r, v)

\* When a shutdown operation completes, the shutdown root
\* must be the last to die.
ShutdownRootDiesLast ≜
  ∀ root ∈ PID :
    ∧ snapshot[root] ≠ {}
    ∧ closing[root] = {}
    ⇒ LET died ≜ DeathsFor(root) IN
        ∧ Len(died) = Cardinality(snapshot[root])
        ∧ died[Len(died)] = root

\* If any shutdown is in progress, eventually all complete.
ShutdownCompletes ≜
  □ ((GlobalClosingSet ≠ {}) ⇒ ◇ (GlobalClosingSet = {}))

Safety ≜
  ∧ TypeInv
  ∧ SingleRoot
  ∧ NoOrphans
  ∧ DisjointClosings
  ∧ DepthInvariant
  ∧ ShutdownRootDiesLast
  ∧ ShutdownCompletes
  ∧ PostOrderDeaths

(***************************************************************************)
(* TLC Views / Refinement Mapping                                          *)
(* Tools for model checking and verification against the abstract spec.    *)
(***************************************************************************)

\* Simplified view for TLC to keep state space manageable during model checking.
View ≜ ⟨ Live, closing, deaths ⟩

\* Map this concrete implementation to the abstract specification.
\* This proves that TaskScope correctly implements AbstractTaskTree.
Mapping ≜
  INSTANCE AbstractTaskTree
    WITH Live     ← Live,      \* Same live set
         Parent   ← parent,    \* Same parent mapping
         DeathLog ← deaths     \* Same death log

\* The refinement property: this spec implements the abstract one.
Refinement ≜ Mapping!Spec

=============================================================================