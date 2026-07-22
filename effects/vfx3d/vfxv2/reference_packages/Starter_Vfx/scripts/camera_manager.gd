class_name CameraManager
extends Camera3D

@export var sensitivity: float = 0.2
@export var speed: float = 5.0

func _process(delta: float) -> void:
	var input_dir := Vector2.ZERO
	
	input_dir.x = Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left")
	input_dir.y = Input.get_action_strength("ui_down") - Input.get_action_strength("ui_up")
	
	if Input.is_physical_key_pressed(KEY_D): input_dir.x += 1.0
	if Input.is_physical_key_pressed(KEY_A): input_dir.x -= 1.0
	if Input.is_physical_key_pressed(KEY_S): input_dir.y += 1.0
	if Input.is_physical_key_pressed(KEY_W): input_dir.y -= 1.0
	
	input_dir = input_dir.normalized()
	
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	position += direction * speed * delta


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		
		rotate_y(deg_to_rad(-event.relative.x * sensitivity))
		
		rotate_object_local(Vector3.RIGHT, deg_to_rad(-event.relative.y * sensitivity))
		
		rotation.x = clamp(rotation.x, deg_to_rad(-80), deg_to_rad(80))
		
		rotation.z = 0.0
