@echo off
cd /d "%~dp0.."
echo Running NetworkService regression gates via tools\run_gates.ps1 ...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_gates.ps1 -Names cold_parse_chain_check,dynamic_call_check,seat_identity_check,room_service_check,custom_room_1028_check,party_lobby_rules_check,lobby050607_check,lobby_identity03_check,reconnect_check,reconnect_service_check,dedicated_server_check,replay_delivery_check,replay_transfer_check,round_settlement_check,final_settlement_check,settlement_ack_retry_check,server_result_ack_check,chat_check,rate_limit_check,dtls_check,handshake_check,network_transport_check,match_state_check,matchmaking_check,empty_match_expiry_check,voice_check,party_voice_ui_check,match_exit_check,mobile_reconnect_check,active_match_check
echo.
echo Done. Summary: reports\checks\summary.json
pause
