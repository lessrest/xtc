----------- MODULE ChannelManyWaiters -----------------------------

EXTENDS Naturals, Sequences

\* This is currently modeling a set of channels with fiber readers
\* and thread writers, I think?
\*
\* Blocking reads are modeled as fiber suspension.
\*
\* Blocking writes are just lack of progress when the queue is full.
\*
\* This is kind of a real scenario?
\* Like a HTTP request thread that delivers events to a fiber.
\*
\* We also don't model fairness for the readers...

CONSTANTS Fiber, Chan, QueueLimit, HistoryLimit, None

LOCAL ℕ ≜ Nat

ASSUME QueueLimit   ∈ ℕ ∧ QueueLimit > 0
ASSUME HistoryLimit ∈ ℕ ∧ HistoryLimit > 0

VARIABLE buffers
VARIABLE status
VARIABLE readers
VARIABLE sendlog
VARIABLE readlog
VARIABLE whoread

Status ≜ {"open", "shut", "dead"}

vars ≜
  ⟨ buffers, status, readers,
    sendlog, readlog, whoread ⟩

ModelCheckingBound ≜
  ∀c ∈ Chan : Len(buffers[c]) ≤ HistoryLimit

SendToken ≜ ℕ
ReadToken ≜ ℕ \cup {None}

SystemInitialization ≜
  ∧ buffers = [c ∈ Chan ↦ ⟨⟩]
  ∧ status  = [c ∈ Chan ↦ "open"]
  ∧ readers = [c ∈ Chan ↦ ⟨⟩]
  ∧ sendlog = [c ∈ Chan ↦ ⟨⟩]
  ∧ readlog = [c ∈ Chan ↦ ⟨⟩]
  ∧ whoread = [c ∈ Chan ↦ ⟨⟩]

Full(c) ≜ Len(buffers[c]) = QueueLimit

BufferEmpty(c) ≜ Len(buffers[c]) = 0

HasReader(c) ≜ readers[c] ≠ ⟨⟩

WaitsFor(c, f) ≜ ∃i ∈ 1‥Len(readers[c]) : readers[c][i] = f

FirstReader(c) ≜ readers[c][1]

SomeReader(c) ≜ CHOOSE f ∈ Fiber : WaitsFor(c, f)

RemainingWaiters(c) ≜ SubSeq(readers[c], 2, Len(readers[c]))

\* This bounds the model size. It also simulates a shutdown.
\* We have to explicitly close the channel to satisfy the liveness
\* property that blocked readers finish.
ChannelTired(c) ≜
  \/ Len(sendlog[c]) >= HistoryLimit
  \/ Len(readlog[c]) >= HistoryLimit

Distinct(s) ≜
  ∀i, j ∈ 1‥Len(s) : i ≠ j ⇒ s[i] ≠ s[j]

PrefixOf(p, s) ≜
  Len(p) ≤ Len(s) ∧ SubSeq(s, 1, Len(p)) = p

Nonce(c) ≜ Len(sendlog[c]) + 1

LogSend(c, m) ≜
  sendlog' = [sendlog EXCEPT ![c] = Append(sendlog[c], m)]

LogRead(c, m) ≜
  readlog' = [readlog EXCEPT ![c] = Append(readlog[c], m)]

LogWhom(c, f) ≜
  whoread' = [whoread EXCEPT ![c] = Append(whoread[c], f)]

AddReader(c, f) ≜
  readers' = [readers EXCEPT ![c] = Append(readers[c], f)]

Remove(s, x) ≜ LET Keep(y) ≜ y # x IN SelectSeq(s, Keep)

RemoveReader(c, f) ≜
  readers' = [readers EXCEPT ![c] = Remove(readers[c], f)]

AddMessageToBuffer(c, m) ≜
  buffers' = [buffers EXCEPT ![c] = Append(buffers[c], m)]

Dequeue(c, m) ≜
  buffers' = [buffers EXCEPT ![c] = Remove(buffers[c], m)]

Open(c) ≜ status[c] = "open"

BlockingRead(c) ≜
  ∧ Open(c)
  ∧ ¬ ChannelTired(c)
  ∧ BufferEmpty(c)
  ∧ ¬ HasReader(c)
  ∧ \E f ∈ Fiber : AddReader(c, f)
  ∧ UNCHANGED ⟨buffers, status, sendlog, readlog, whoread⟩

RendezvousSend(c) ≜
  ∧ Open(c)
  ∧ ¬ ChannelTired(c)
  ∧ HasReader(c)
  ∧ LET f ≜ SomeReader(c) IN
    ∧ RemoveReader(c, f)
    ∧ LogSend(c, Nonce(c))
    ∧ LogRead(c, Nonce(c))
    ∧ LogWhom(c, f)
  ∧ UNCHANGED ⟨buffers, status⟩

BufferedSend(c) ≜
  ∧ Open(c)
  ∧ ¬ ChannelTired(c)
  ∧ ¬ HasReader(c)
  ∧ ¬ Full(c)
  ∧ AddMessageToBuffer(c, Nonce(c))
  ∧ LogSend(c, Nonce(c))
  ∧ UNCHANGED ⟨status, readers, readlog, whoread⟩

BufferedRead(c) ≜
  ∧ Open(c)
  ∧ ¬ ChannelTired(c)
  ∧ ¬ BufferEmpty(c)
  ∧ ¬ HasReader(c)
  ∧ LET f == CHOOSE f ∈ Fiber : TRUE IN
    ∧ LogRead(c, Head(buffers[c]))
    ∧ LogWhom(c, f)
    ∧ Dequeue(c, Head(buffers[c]))
    ∧ UNCHANGED ⟨status, readers, sendlog⟩

HopelessRead(c) ≜
  ∧ ¬ Open(c)
  ∧ BufferEmpty(c)
  ∧ HasReader(c)
  ∧ readers' = [readers EXCEPT ![c] = ⟨⟩]
  ∧ UNCHANGED ⟨buffers, status, sendlog, readlog, whoread⟩

ChannelClosed(c) ≜
  ∧ Open(c)
  ∧ status' = [status EXCEPT ![c] = "shut"]
  ∧ UNCHANGED ⟨buffers, readers, sendlog, readlog, whoread⟩

ChannelExiting(c) ≜
  ∧ Open(c)
  ∧ ChannelTired(c)
  ∧ ChannelClosed(c)
  ∧ UNCHANGED ⟨buffers, readers, sendlog, readlog, whoread⟩

\* Blocking reads can timeout or otherwise be canceled voluntarily.
\* For sanity, all blocking operations should have finite timeout.
CancelledRead(c) ≜
  /\ HasReader(c)
  /\ BufferEmpty(c)
  /\ LET f == SomeReader(c) IN
    /\ readers' = [readers EXCEPT ![c] = Remove(readers[c], f)]
    /\ LogRead(c, None)
    /\ UNCHANGED << status, buffers, sendlog, whoread >>

\* No readers are blocking on any channel?
\* Runtime is likely to wind down.
SystemDone ==
  /\ ~ \E c \in Chan : HasReader(c)
  /\ (\A c ∈ Chan : status[c] # "open")
  /\ status' = [c ∈ Chan ↦ "dead"]
  /\ buffers' = [c ∈ Chan ↦ ⟨⟩]
  /\ UNCHANGED << sendlog, readlog, readers, whoread >>

ChannelTransition(c) ≜
  ∨ BufferedSend(c)    \* writer put message into channel buffer
  ∨ RendezvousSend(c)  \* rendezvous send without channel buffer
  ∨ BufferedRead(c)    \* reader got message from channel buffer
  ∨ BlockingRead(c)    \* reader now awaiting the channel buffer
  ∨ CancelledRead(c)   \* reader is not reading anymore; timeout
  ∨ HopelessRead(c)    \* channel shutting down, reader notified
  ∨ ChannelClosed(c)   \* writer closed their end of the channel
  ∨ ChannelExiting(c)  \* channel is winding down systematically

SystemTransition ≜
  ∨ ∃ c ∈ Chan : ChannelTransition(c)
  ∨ SystemDone

Fairness(c) ≜
  WF_vars(
    \/ CancelledRead(c)
    \/ ChannelExiting(c)
    \/ HopelessRead(c)
    \/ BufferedSend(c)
    \/ RendezvousSend(c)
    \/ BufferedRead(c)
  )

CompleteSpecification ≜
  ∧ SystemInitialization
  ∧ □ [SystemTransition]_vars
  ∧ ∀ c ∈ Chan : Fairness(c)
  /\ WF_vars(SystemDone)

TypeSafetyInvariant ≜
  ∧ buffers   ∈ [Chan → Seq(SendToken)]
  ∧ status    ∈ [Chan → Status]
  ∧ readers   ∈ [Chan → Seq(Fiber)]
  ∧ sendlog   ∈ [Chan → Seq(SendToken)]
  ∧ readlog   ∈ [Chan → Seq(ReadToken)]
  ∧ whoread   ∈ [Chan → Seq(Fiber)]
  ∧ ∀ c ∈ Chan : Len(whoread[c]) ≤ Len(sendlog[c])
  ∧ ∀ c ∈ Chan : Len(buffers[c]) ≤ QueueLimit
  ∧ ∀ c ∈ Chan : Distinct(readers[c])

IsSuccessfulRead(x) == x # None
ProperReadlog(c) == SelectSeq(readlog[c], IsSuccessfulRead)

FIFOOrderingInvariant ≜
  ∀ c ∈ Chan : PrefixOf(ProperReadlog(c), sendlog[c])

MessageConservationInvariant ≜
  ∀ c ∈ Chan :
    \/ /\ status[c] # "dead"
       /\ sendlog[c] = ProperReadlog(c) \o buffers[c]
    \/ /\ status[c] = "dead"
       /\ PrefixOf(ProperReadlog(c), sendlog[c])
       /\ BufferEmpty(c)

BlockingReadersImplyEmptyBuffer ≜
  \A c ∈ Chan : HasReader(c) => BufferEmpty(c)

Safety ≜
  ∧ □ TypeSafetyInvariant
  ∧ □ FIFOOrderingInvariant
  ∧ □ MessageConservationInvariant
  ∧ □ BlockingReadersImplyEmptyBuffer

ReadersEventuallyGoAway ≜
  ∀ c ∈ Chan : [] (HasReader(c) => <> ¬ HasReader(c))

ChannelsEventuallyWindDown ==
  \A c \in Chan :
    [] (<> /\ status[c] # "open"
           /\ BufferEmpty(c)
           /\ ~ HasReader(c))

Includes(s, x) ≜
  ∃ i ∈ 1‥Len(s) : s[i] = x

=============================================================================