module Membrane.Element.LiveAudioMixer.Timer

spec start_sender(pid, interval :: unsigned, delay :: unsigned) ::
       {:ok :: label, state} | {:error :: label, reason :: atom}

spec stop_sender(state) :: (:ok :: label) | {:error :: label, :stopped :: label}

sends {:tick :: label, cur_tick :: unsigned}
