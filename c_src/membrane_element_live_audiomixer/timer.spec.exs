module Membrane.Element.LiveAudioMixer.Timer.LibShout

spec start_native_sender(pid, interval :: uint64, delay :: uint64) ::
       {:ok :: label, state} | {:error :: label, reason :: atom}

spec stop_native_sender(state) :: (:ok :: label) | {:error :: label, :stopped :: label}

spec native_time() :: time :: uint64

dirty :io, stop_native_sender: 1

sends {:tick :: label, cur_time :: uint64}
