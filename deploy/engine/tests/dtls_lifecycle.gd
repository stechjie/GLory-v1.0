extends SceneTree
# Run in a disposable empty project. No production files or keys are read.
var server: ENetMultiplayerPeer
var client: ENetMultiplayerPeer
var healthy: ENetMultiplayerPeer
var key: CryptoKey
var cert: X509Certificate
var failures := 0
var checks := 0
var peers: Array = []
func _initialize():
	Engine.max_fps = 120
	call_deferred("run")
func expect(ok: bool, label: String):
	checks += 1
	if not ok:
		failures += 1
	print("ASSERT ", label, " ", ok)
func tick(ms: int):
	var stop := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < stop:
		server.poll()
		for peer in [client, healthy]:
			if peer != null and peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
				peer.poll()
		await process_frame
func make_client(pin: X509Certificate, port: int, local_port: int = 0) -> ENetMultiplayerPeer:
	var peer := ENetMultiplayerPeer.new()
	expect(peer.create_client("127.0.0.1", port, 0, 0, 0, local_port) == OK, "create_client")
	if pin != null:
		expect(peer.get_host().dtls_client_setup("local-test", TLSOptions.client_unsafe(pin)) == OK, "dtls_setup")
	return peer
func connected(peer: ENetMultiplayerPeer) -> bool:
	return peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and peers.has(peer.get_unique_id())
func exchange(peer: ENetMultiplayerPeer):
	var payload := PackedByteArray()
	payload.resize(16384)
	for i in payload.size():
		payload[i] = i % 251
	peer.set_target_peer(1)
	peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
	expect(peer.put_packet(payload) == OK, "send_16k")
	await tick(700)
	var received := false
	while server.get_available_packet_count() > 0:
		received = server.get_packet() == payload or received
	expect(received, "encrypted_fragmented_payload")
func run():
	var crypto := Crypto.new()
	key = crypto.generate_rsa(2048)
	cert = crypto.generate_self_signed_certificate(key, "CN=local-test", "20200101000000", "20400101000000")
	server = ENetMultiplayerPeer.new()
	server.set_bind_ip("127.0.0.1")
	expect(server.create_server(0, 16) == OK, "listen")
	server.peer_connected.connect(func(id): peers.append(id))
	server.peer_disconnected.connect(func(id): peers.erase(id))
	expect(server.get_host().dtls_server_setup(TLSOptions.server(key, cert)) == OK, "server_dtls")
	var port := server.get_host().get_local_port()
	healthy = make_client(cert, port)
	await tick(1200)
	expect(connected(healthy), "healthy_connected")
	# Bind once to select a free client port, then reuse it through all reconnects.
	var reservation := PacketPeerUDP.new()
	expect(reservation.bind(0, "127.0.0.1") == OK, "reserve_port")
	var local_port := reservation.get_local_port()
	reservation.close()
	print("TEST_ENDPOINT server=127.0.0.1:", port, " reused_client_port=", local_port)
	for mode in ["client_close", "server_disconnect", "client_graceful"]:
		for n in range(3):
			print("CASE_START ", mode, " ", n)
			client = make_client(cert, port, local_port)
			await tick(1200)
			expect(connected(client), "reconnected_same_port")
			if connected(client):
				await exchange(client)
				if mode == "server_disconnect":
					server.disconnect_peer(client.get_unique_id())
					await tick(300)
				elif mode == "client_graceful":
					client.disconnect_peer(1)
					await tick(300)
			client.close()
			client = null
			await tick(1200)
			expect(peers.size() == 1, "disconnected_peer_removed")
			expect(connected(healthy), "other_client_survives")
			print("CASE_END ", mode)
	# Unknown endpoints sending encrypted alerts/data must not create fresh handshakes.
	print("CASE_START stale_datagrams")
	var udp := PacketPeerUDP.new()
	udp.connect_to_host("127.0.0.1", port)
	for type in [21, 23, 20, 0]:
		var data := PackedByteArray([type, 254, 253, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0])
		udp.put_packet(data)
		await tick(100)
	udp.close()
	await exchange(healthy)
	print("CASE_END stale_datagrams")
	print("CASE_START plaintext_rejected")
	client = make_client(null, port)
	await tick(2200)
	expect(not connected(client), "plaintext_rejected")
	client.close()
	client = null
	print("CASE_END plaintext_rejected")
	print("CASE_START wrong_cert_rejected")
	var other_key := crypto.generate_rsa(2048)
	var other_cert := crypto.generate_self_signed_certificate(other_key, "CN=local-test", "20200101000000", "20400101000000")
	client = make_client(other_cert, port)
	await tick(2200)
	expect(not connected(client), "wrong_cert_rejected")
	client.close()
	client = null
	print("CASE_END wrong_cert_rejected")
	await exchange(healthy)
	healthy.close()
	healthy = null
	await tick(300)
	server.close()
	print("RESULT checks=", checks, " failures=", failures)
	quit(1 if failures else 0)
