----------------------------- MODULE TaskScope -----------------------------
EXTENDS FiniteSets, Sequences, Naturals

\* Concrete Task Tree with Stepwise Shutdown
\*
\* - Live     : the set of currently live tasks.
\* - Eggs     : tasks not yet spawned (finite pool PID).
\* - parent   : parent mapping (roots self-parented, others point to parent)
\* - births   : log of birth events.
\* - deaths   : log of reaped tasks (leaf-first order).
\* - closing  : for each root, the set of nodes currently being shut down.
\* - closeInit: snapshot of the subtree at BeginShutdown, for each root.
\* - rank     : depth snapshot at BeginShutdown (used for order checks).
\* - root0    : snapshot of which node was the root of each shutdown.
\* - depth    : current depth rank of each node in Live.

CONSTANTS PID
VARIABLES Live, Eggs, parent, births, deaths,
          closing, closeInit, rank, root0, depth

None == "none"

vars == << Live, Eggs, parent, births, deaths,
           closing, closeInit, rank, root0, depth >>

(***************************************************************************)
(* Initialization                                                          *)
(***************************************************************************)

Init ==
  \E r \in PID :
    /\ Live = { r }
    /\ Eggs = PID \ { r }
    /\ parent = [ p \in PID |-> IF p = r THEN r ELSE None ]
    /\ births = << >>
    /\ deaths = << >>
    /\ closing   = [p \in PID |-> {}]
    /\ closeInit = [p \in PID |-> {}]
    /\ rank      = [p \in PID |-> [q \in PID |-> 0]]
    /\ root0     = [p \in PID |-> p]
    /\ depth     = [p \in PID |-> IF p = r THEN 0 ELSE 0]

(***************************************************************************)
(* Helpers                                                                 *)
(***************************************************************************)

Roots       == { p \in Live : parent[p] = p }
Children(p) == { q \in Live : parent[q] = p /\ q # p }

RECURSIVE Descendants(_)
Descendants(p) == Children(p) \cup UNION { Descendants(c) : c \in Children(p) }

Subtree(p) == {p} \cup Descendants(p)

\* Leaf of a closing set (no children inside that closing set).
Leaf(r, x) ==
  /\ x \in closing[r]
  /\ \A y \in closing[r] : parent[y] # x

\* Restrict deaths log to nodes of a particular shutdown snapshot.
DeathsFor(r) == SelectSeq(deaths, LAMBDA x : x \in closeInit[r])

(***************************************************************************)
(* Actions                                                                 *)
(***************************************************************************)

\* Spawn a fresh child under a live parent, if parent not inside any closing subtree.
Birth(parentId, child) ==
  /\ parentId \in Live
  /\ \A r \in PID : parentId \notin closing[r]
  /\ child \in Eggs
  /\ Live'   = Live \cup {child}
  /\ Eggs'   = Eggs \ {child}
  /\ parent' = [parent EXCEPT ![child] = parentId]
  /\ births' = births \o <<child>>
  /\ depth'  = [depth EXCEPT ![child] = depth[parentId] + 1]
  /\ UNCHANGED << deaths, closing, closeInit, rank, root0 >>

\* Start shutting down a subtree rooted at p (non-root).
BeginShutdown(p) ==
  /\ p \in Live /\ p \notin Roots
  /\ \A r \in PID : closing[r] = {} \/ Subtree(p) \cap closing[r] = {}
  /\ LET S == Subtree(p) IN
       /\ closing'   = [closing   EXCEPT ![p] = S]
       /\ closeInit' = [closeInit EXCEPT ![p] = S]
       /\ root0'     = [root0     EXCEPT ![p] = p]
       /\ rank'      = [rank      EXCEPT ![p] =
                           [q \in PID |-> IF q \in S THEN depth[q] ELSE 0]]
  /\ UNCHANGED << Live, Eggs, parent, births, deaths, depth >>

\* Remove one leaf from an active shutdown.
ReapStep(r, x) ==
  /\ x \in Live
  /\ Leaf(r, x)
  /\ Live'   = Live \ {x}
  /\ parent' = [q \in PID |-> IF q = x THEN None ELSE parent[q]]
  /\ depth'  = [q \in PID |-> IF q = x THEN 0 ELSE depth[q]]
  /\ deaths' = deaths \o <<x>>
  /\ closing' = [t \in PID |-> closing[t] \ {x}]
  /\ UNCHANGED << births, closeInit, rank, root0, Eggs >>

Next ==
   \/ \E p, c \in PID : Birth(p, c)
   \/ \E p \in PID     : BeginShutdown(p)
   \/ \E r, x \in PID  : ReapStep(r, x)

Spec ==
  Init /\ [][Next]_vars
  /\ WF_vars(\E r, x \in PID : ReapStep(r,x))   \* shutdowns eventually finish

(***************************************************************************)
(* Safety Invariants                                                       *)
(***************************************************************************)

\* Typing and domain constraints.
TypeInv ==
  /\ Live \subseteq PID
  /\ Eggs \subseteq PID
  /\ Live \cap Eggs = {}
  /\ parent \in [PID -> PID \cup {None}]
  /\ births \in Seq(PID)
  /\ deaths \in Seq(PID)
  /\ closing   \in [PID -> SUBSET PID]
  /\ closeInit \in [PID -> SUBSET PID]
  /\ rank      \in [PID -> [PID -> Nat]]
  /\ root0     \in [PID -> PID]
  /\ depth     \in [PID -> Nat]
  /\ \A r \in PID : closing[r] \subseteq Live

\* Exactly one root.
SingleRoot ==
  Cardinality({ p \in Live : parent[p] = p }) = 1

\* No orphans: every non-root child points to a live parent.
NoOrphans ==
  \A c \in Live \ Roots : parent[c] \in Live

\* Distinct shutdowns don’t overlap.
DisjointClosings ==
  \A r1, r2 \in PID : r1 # r2 => closing[r1] \cap closing[r2] = {}

\* Depth is consistent with parent chain.
DepthInvariant ==
  \A p \in Live :
    IF parent[p] = p THEN depth[p] = 0
    ELSE depth[p] = depth[parent[p]] + 1

\* Order of deaths: snapshot rank must never increase (children before parent).
NonIncreasingRank(r) ==
  LET df == DeathsFor(r) IN
    \A i, j \in 1..Len(df) : i < j => rank[r][df[i]] >= rank[r][df[j]]

NonIncreasingRankInv ==
  \A r \in PID : NonIncreasingRank(r)

\* When a shutdown finishes, its root dies last.
RootLastWhenDone(r) ==
  /\ closeInit[r] # {}
  /\ closing[r] = {}
  => LET df == DeathsFor(r) IN
       /\ Len(df) = Cardinality(closeInit[r])
       /\ df[Len(df)] = root0[r]

RootLastWhenDoneInv ==
  \A r \in PID : RootLastWhenDone(r)

\* Shutdowns don’t stall forever.
ShutdownCompletes ==
  [] ( (∃ r ∈ PID : closing[r] # {}) ⇒ <> (∀ r ∈ PID : closing[r] = {}) )

\* Bundle them all.
Safety ==
  /\ TypeInv
  /\ SingleRoot
  /\ NoOrphans
  /\ DisjointClosings
  /\ DepthInvariant
  /\ NonIncreasingRankInv
  /\ RootLastWhenDoneInv

(***************************************************************************)
(* TLC Views / Refinement Mapping                                          *)
(***************************************************************************)

\* View: keep traces small and readable
View == << Live, closing, deaths >>

\* Refinement mapping to abstract spec
Mapping ==
  INSTANCE AbstractTaskTree
    WITH Live     <- Live,
         Parent   <- parent,
         DeathLog <- deaths

Refinement == Mapping!Spec

=============================================================================