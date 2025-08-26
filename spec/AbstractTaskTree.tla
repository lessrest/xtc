--------------------------- MODULE AbstractTaskTree ---------------------------
EXTENDS FiniteSets, Sequences, Naturals

(***************************************************************************)
(* Abstract Task Tree                                                       *)
(*                                                                         *)
(* This specification defines the observable behavior of a hierarchical     *)
(* task management system. Tasks form trees, spawn children, and are       *)
(* shutdown in leaf-first order (children before parents).                 *)
(*                                                                         *)
(* Key properties:                                                         *)
(*   - Tasks organize into tree structures over the Live set               *)
(*   - New tasks are spawned as children of existing live tasks            *)
(*   - Shutdown removes only leaves (tasks with no live children)          *)
(*   - DeathLog records the order of task termination                      *)
(*                                                                         *)
(* This is the abstract specification - it defines WHAT happens but not    *)
(* HOW shutdown is coordinated or scheduled.                               *)
(*                                                                         *)
(* Variables:                                                              *)
(* - PID        : finite set of task identifiers                           *)
(* - Live       : currently running tasks                                  *)
(* - Parent     : parent mapping for all PIDs (roots point to themselves)  *)
(* - DeathLog   : sequence of terminated tasks (leaf-first order)          *)
(***************************************************************************)

CONSTANTS PID

VARIABLES Live, Parent, DeathLog
vars == << Live, Parent, DeathLog >>

(***************************************************************************)
(* Typing & structural conventions                                         *)
(* These functions define the basic structure of the task tree.            *)
(***************************************************************************)

\* A root task has no parent - it points to itself in the Parent mapping.
IsRoot(p)    == Parent[p] = p
\* The set of all root tasks currently running.
Roots        == { p \in Live : IsRoot(p) }

\* Children of p are live tasks that have p as their parent (excluding p itself).
Children(p)  == { q \in Live : Parent[q] = p /\ q # p }

\* Recursively find all descendants (children, grandchildren, etc.) of p.
RECURSIVE Descendants(_)
Descendants(p) ==
  Children(p) \cup UNION { Descendants(c) : c \in Children(p) }

\* The subtree rooted at p includes p itself plus all its descendants.
Subtree(p)   == { p } \cup Descendants(p)

\* A leaf task is one that's alive but has no children - these are the only 
\* tasks that can be reaped (shutdown).
IsLeaf(p)    == p \in Live /\ Children(p) = {}

(***************************************************************************)
(* Initialization                                                          *)
(***************************************************************************)

Init ==
  \E r \in PID :
    /\ Live      = { r }
    /\ Parent    = [ p \in PID |-> IF p = r THEN r ELSE "none" ]
    /\ DeathLog  = << >>

(***************************************************************************)
(* Actions                                                                 *)
(***************************************************************************)

\* Birth: spawn a new task 'c' as a child of existing task 'p'.
Birth(p, c) ==
  /\ p \in Live                     \* Parent must be alive
  /\ c \in PID \ Live                 \* Child must not already exist
  /\ Live'      = Live \cup { c }       \* Add child to live set
  /\ Parent'    = [ Parent EXCEPT ![c] = p ]  \* Set p as c's parent
  /\ DeathLog'  = DeathLog              \* Death log unchanged

\* Reap: shutdown a leaf task (one with no children).
Reap(x) ==
  /\ IsLeaf(x)                      \* Can only reap leaves
  /\ Live'      = Live \ { x }         \* Remove from live set
  /\ Parent'    = [ q \in PID |-> IF q = x THEN "none" ELSE Parent[q] ]  \* Clear parent
  /\ DeathLog'  = DeathLog \o << x >>   \* Record the death

Next ==
  \/ \E p, c \in PID : Birth(p, c)
  \/ \E x   \in PID : Reap(x)

Spec == Init /\ [][Next]_vars

\* Parent is always total over PID; on Live, roots are self-parented and
\* non-roots’ parents are Live (forest of trees over Live).
TypingInv ==
  /\ Parent \in [ PID -> (PID \cup { "none" }) ]
  /\ DeathLog \in Seq(PID)
  /\ \A p \in Live :
       IF IsRoot(p) THEN TRUE
       ELSE Parent[p] \in Live

\* Leaf-first reaping implies a global post-order: no ancestor appears
\* before any of its descendants in DeathLog (with respect to the state
\* when they were both live). This is implied by the step rule but handy
\* to assert for documentation/testing on small PID.
PostOrderInv ==
  \A i, j \in 1..Len(DeathLog) :
     i < j => ~( DeathLog[i] \in Descendants(DeathLog[j]) )

=============================================================================