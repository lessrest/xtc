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
(* - BeginShutdown captures a subtree snapshot for orderly teardown       *)
(* - Closing tracks progress through the shutdown sequence                 *)
(* - Rank preserves depth information to enforce post-order traversal     *)
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
(* - closeInit: snapshot of subtree when shutdown began, per operation     *)
(* - rank     : depth snapshot at shutdown time (for ordering verification) *)
(* - root0    : which task initiated each shutdown operation              *)
(* - depth    : current depth of each live task in the hierarchy          *)
(***************************************************************************)

CONSTANTS PID
VARIABLES Live, Eggs, parent, births, deaths,
          closing, closeInit, rank, root0, depth

\* Sentinel value for tasks that have no parent (cleared on death).
None == "none"

\* All state variables bundled for convenience.
vars == << Live, Eggs, parent, births, deaths,
           closing, closeInit, rank, root0, depth >>

(***************************************************************************)
(* Initialization                                                          *)
(* Start with one root task, empty logs, and no active shutdowns.         *)
(***************************************************************************)

Init ==
  \E r \in PID :  \* Choose some task to be the initial root
    /\ Live = { r }                     \* Only root is alive initially
    /\ Eggs = PID \ { r }               \* All other PIDs available for spawning
    /\ parent = [ p \in PID |-> IF p = r THEN r ELSE None ]  \* Root is self-parented
    /\ births = << >>                   \* No births yet
    /\ deaths = << >>                   \* No deaths yet
    /\ closing   = [p \in PID |-> {}]   \* No shutdowns in progress
    /\ closeInit = [p \in PID |-> {}]   \* No shutdown snapshots
    /\ rank      = [p \in PID |-> [q \in PID |-> 0]]  \* No depth snapshots
    /\ root0     = [p \in PID |-> p]    \* Default mapping (unused initially)
    /\ depth     = [p \in PID |-> IF p = r THEN 0 ELSE 0]  \* Root at depth 0

(***************************************************************************)
(* Helpers                                                                 *)
(* Functions to navigate the task tree structure and shutdown state.      *)
(***************************************************************************)

\* Root tasks are self-parented.
Roots       == { p \in Live : parent[p] = p }
\* Children are live tasks with this parent (excluding self-reference).
Children(p) == { q \in Live : parent[q] = p /\ q # p }

\* Recursively find all descendants in the live tree.
RECURSIVE Descendants(_)
Descendants(p) == Children(p) \cup UNION { Descendants(c) : c \in Children(p) }

\* Complete subtree including the root node itself.
Subtree(p) == {p} \cup Descendants(p)

\* Check if x is a leaf within the closing set r - it has no children 
\* that are also in the closing set (meaning it can be safely reaped).
Leaf(r, x) ==
  /\ x \in closing[r]                    \* x must be in the closing set
  /\ \A y \in closing[r] : parent[y] # x \* x has no children in closing[r]

\* Extract from the deaths log only those tasks that were part of 
\* shutdown r's original snapshot.
DeathsFor(r) == SelectSeq(deaths, LAMBDA x : x \in closeInit[r])

(***************************************************************************)
(* Actions                                                                 *)
(* The three operations: spawn tasks, initiate shutdown, process shutdown. *)
(***************************************************************************)

\* Spawn a new task as a child of an existing parent.
\* Cannot spawn children under parents that are being shut down.
Birth(parentId, child) ==
  /\ parentId \in Live                  \* Parent must be running
  /\ \A r \in PID : parentId \notin closing[r]  \* Parent not being shut down
  /\ child \in Eggs                     \* Child not already spawned
  /\ Live'   = Live \cup {child}        \* Add child to live set
  /\ Eggs'   = Eggs \ {child}           \* Remove from available pool
  /\ parent' = [parent EXCEPT ![child] = parentId]  \* Set parent relationship
  /\ births' = births \o <<child>>      \* Log the birth
  /\ depth'  = [depth EXCEPT ![child] = depth[parentId] + 1]  \* Child one level deeper
  /\ UNCHANGED << deaths, closing, closeInit, rank, root0 >>  \* No change to shutdown state

\* Begin shutdown process for a subtree rooted at p.
\* Takes a snapshot of the subtree to ensure orderly leaf-first teardown.
BeginShutdown(p) ==
  /\ p \in Live /\ p \notin Roots       \* Can't shutdown root tasks
  /\ \A r \in PID : closing[r] = {} \/ Subtree(p) \cap closing[r] = {}  \* No conflicting shutdowns
  /\ LET S == Subtree(p) IN             \* Snapshot the current subtree
       /\ closing'   = [closing   EXCEPT ![p] = S]     \* Mark these tasks as closing
       /\ closeInit' = [closeInit EXCEPT ![p] = S]     \* Remember the original snapshot
       /\ root0'     = [root0     EXCEPT ![p] = p]     \* Remember shutdown root
       /\ rank'      = [rank      EXCEPT ![p] =        \* Capture depth for ordering
                           [q \in PID |-> IF q \in S THEN depth[q] ELSE 0]]
  /\ UNCHANGED << Live, Eggs, parent, births, deaths, depth >>  \* No immediate changes

\* Remove one leaf task from an active shutdown operation.
\* This is the core of the leaf-first reaping process.
ReapStep(r, x) ==
  /\ x \in Live                        \* Task must be alive
  /\ Leaf(r, x)                        \* Must be a leaf in shutdown r's closing set
  /\ Live'   = Live \ {x}              \* Remove from live tasks
  /\ parent' = [q \in PID |-> IF q = x THEN None ELSE parent[q]]  \* Clear parent link
  /\ depth'  = [q \in PID |-> IF q = x THEN 0 ELSE depth[q]]      \* Reset depth
  /\ deaths' = deaths \o <<x>>         \* Record the death
  /\ closing' = [t \in PID |-> closing[t] \ {x}]  \* Remove from all closing sets
  /\ UNCHANGED << births, closeInit, rank, root0, Eggs >>  \* Snapshots unchanged

\* The system can perform any of three actions.
Next ==
   \/ \E p, c \in PID : Birth(p, c)        \* Spawn new tasks
   \/ \E p \in PID     : BeginShutdown(p)  \* Initiate shutdown
   \/ \E r, x \in PID  : ReapStep(r, x)    \* Process shutdown step

\* Complete specification with fairness constraint to ensure shutdowns complete.
Spec ==
  Init /\ [][Next]_vars
  /\ WF_vars(\E r, x \in PID : ReapStep(r,x))   \* shutdowns eventually finish

(***************************************************************************)
(* Safety Invariants                                                       *)
(* Properties that must hold in every reachable state.                    *)
(***************************************************************************)

\* Basic type safety and domain constraints.
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

\* System maintains exactly one root task at all times.
SingleRoot ==
  Cardinality({ p \in Live : parent[p] = p }) = 1

\* No orphaned tasks: every non-root has a live parent.
NoOrphans ==
  \A c \in Live \ Roots : parent[c] \in Live

\* Concurrent shutdowns don't interfere with each other.
DisjointClosings ==
  \A r1, r2 \in PID : r1 # r2 => closing[r1] \cap closing[r2] = {}

\* Depth tracking is consistent with the parent-child relationships.
DepthInvariant ==
  \A p \in Live :
    IF parent[p] = p THEN depth[p] = 0       \* Roots at depth 0
    ELSE depth[p] = depth[parent[p]] + 1     \* Children one deeper than parent

\* Deaths occur in post-order: rank (depth) must never increase in death sequence.
\* This ensures children die before their parents.
NonIncreasingRank(r) ==
  LET df == DeathsFor(r) IN  \* Deaths for this shutdown operation
    \A i, j \in 1..Len(df) : i < j => rank[r][df[i]] >= rank[r][df[j]]

\* Apply the non-increasing rank property to all shutdown operations.
NonIncreasingRankInv ==
  \A r \in PID : NonIncreasingRank(r)

\* When a shutdown operation completes, the shutdown root must be the last to die.
RootLastWhenDone(r) ==
  /\ closeInit[r] # {}                   \* There was a shutdown operation
  /\ closing[r] = {}                     \* It's now complete (closing set empty)
  => LET df == DeathsFor(r) IN
       /\ Len(df) = Cardinality(closeInit[r])  \* All snapshot tasks died
       /\ df[Len(df)] = root0[r]               \* Root died last

\* Apply the root-last property to all shutdown operations.
RootLastWhenDoneInv ==
  \A r \in PID : RootLastWhenDone(r)

\* Liveness property: if any shutdown is in progress, eventually all complete.
ShutdownCompletes ==
  [] ( (∃ r ∈ PID : closing[r] # {}) ⇒ <> (∀ r ∈ PID : closing[r] = {}) )

\* Collect all safety properties into one invariant.
Safety ==
  /\ TypeInv                 \* Basic typing constraints
  /\ SingleRoot              \* Exactly one root
  /\ NoOrphans               \* No orphaned tasks
  /\ DisjointClosings        \* Shutdowns don't interfere  
  /\ DepthInvariant          \* Consistent depth tracking
  /\ NonIncreasingRankInv    \* Post-order death sequence
  /\ RootLastWhenDoneInv     \* Shutdown roots die last

(***************************************************************************)
(* TLC Views / Refinement Mapping                                          *)
(* Tools for model checking and verification against the abstract spec.    *)
(***************************************************************************)

\* Simplified view for TLC to keep state space manageable during model checking.
View == << Live, closing, deaths >>

\* Map this concrete implementation to the abstract specification.
\* This proves that TaskScope correctly implements AbstractTaskTree.
Mapping ==
  INSTANCE AbstractTaskTree
    WITH Live     <- Live,      \* Same live set
         Parent   <- parent,    \* Same parent mapping  
         DeathLog <- deaths     \* Same death log

\* The refinement property: this spec implements the abstract one.
Refinement == Mapping!Spec

=============================================================================