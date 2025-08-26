--------------------------- MODULE AbstractTaskTree ---------------------------
EXTENDS FiniteSets, Sequences, Naturals

(***************************************************************************)
(* Abstract Task Tree (stepwise, leaf-first)                               *)
(*                                                                         *)
(* - PID is a finite set of task identifiers (fixed in the .cfg).          *)
(* - Live       : the set of currently live tasks.                          *)
(* - Parent     : the parent mapping for ALL PIDs; roots are self-parented. *)
(* - DeathLog   : sequence of tasks reaped so far (leaf-first order).       *)
(*                                                                         *)
(* This model says WHAT the world observes:                                 *)
(*   1) tasks form a tree over Live (roots are self-parented),              *)
(*   2) births attach a fresh child to a live parent,                       *)
(*   3) reaping removes one LEAF at a time, appending it to DeathLog.       *)
(* It intentionally says nothing about how reaping is scheduled.            *)
(***************************************************************************)

CONSTANTS PID

VARIABLES Live, Parent, DeathLog
vars == << Live, Parent, DeathLog >>

(***************************************************************************)
(* Typing & structural conventions                                         *)
(***************************************************************************)

\* A root is self-parented; non-roots point to their (live) parent.
IsRoot(p)    == Parent[p] = p
Roots        == { p \in Live : IsRoot(p) }

\* Children/descendants are only considered among Live tasks.
Children(p)  == { q \in Live : Parent[q] = p /\ q # p }

RECURSIVE Descendants(_)
Descendants(p) ==
  Children(p) \cup UNION { Descendants(c) : c \in Children(p) }

Subtree(p)   == { p } \cup Descendants(p)

\* A leaf is a live task with no live children.
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

\* Birth: attach a fresh child 'c' to a live parent 'p'.
Birth(p, c) ==
  /\ p \in Live
  /\ c \in PID \ Live
  /\ Live'      = Live \cup { c }
  /\ Parent'    = [ Parent EXCEPT ![c] = p ]
  /\ DeathLog'  = DeathLog

\* Reap (one step): remove a live leaf, append it to the log.
Reap(x) ==
  /\ IsLeaf(x)
  /\ Live'      = Live \ { x }
  /\ Parent'    = [ q \in PID |-> IF q = x THEN "none" ELSE Parent[q] ]
  /\ DeathLog'  = DeathLog \o << x >>

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