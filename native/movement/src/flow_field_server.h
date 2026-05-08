#pragma once
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include "types.h"

namespace drossfront {

class FlowFieldServer : public godot::Object {
    GDCLASS(FlowFieldServer, godot::Object)

protected:
    static void _bind_methods();

public:
    FlowFieldServer();
    ~FlowFieldServer();

    // API exposed to GDScript. Stubs in this task — implemented in Phase 2.
    FieldId build_field(godot::Vector3 goal, int agent_class);
    void release_field(FieldId id);
    godot::Vector2 sample(FieldId id, godot::Vector3 world_pos);
    void mark_obstacle(godot::AABB aabb, bool blocked);
    void mark_soft_cost(godot::AABB aabb, int cost);
};

} // namespace drossfront
