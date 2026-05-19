#pragma once
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include "types.h"
#include "flow_field_server_impl.h"

namespace drossfront {

class FlowFieldServer : public godot::Object {
    GDCLASS(FlowFieldServer, godot::Object)

    friend class SteeringKernel;

protected:
    static void _bind_methods();

public:
    FlowFieldServer();
    ~FlowFieldServer();

    // Map setup (called from GDScript at scene start).
    void configure_map(int grid_w, int grid_h, float cell_size,
                       float origin_x, float origin_z)
        { impl_.configure_map(grid_w, grid_h, cell_size, origin_x, origin_z); }

    // Per-class agent radius for dilation (set once at scene start).
    void set_agent_radius(int agent_class, float radius)
        { impl_.set_agent_radius(agent_class, radius); }

    // GDScript-facing API.
    FieldId build_field(godot::Vector3 goal, int agent_class)
        { return impl_.build_field(goal, agent_class); }
    void release_field(FieldId id)
        { impl_.release_field(id); }
    godot::Vector2 sample(FieldId id, godot::Vector3 world_pos)
        { return impl_.sample(id, world_pos); }
    void mark_obstacle(godot::AABB aabb, bool blocked)
        { impl_.mark_obstacle(aabb, blocked); }
    void mark_soft_cost(godot::AABB aabb, int cost)
        { impl_.mark_soft_cost(aabb, cost); }

    // Y-aware Dijkstra support.
    void set_cell_y_at(godot::Vector3 world_pos, float y)
        { impl_.set_cell_y_at(world_pos, y); }

    // Diagnostics.
    int get_cell_cost_at(godot::Vector3 world_pos, int agent_class) const
        { return impl_.get_cell_cost_at(world_pos, agent_class); }
    float get_cell_y_at(godot::Vector3 world_pos) const
        { return impl_.get_cell_y_at(world_pos); }
    int field_count() const { return impl_.field_count(); }
    bool field_exists(FieldId id) const { return impl_.field_exists(id); }

private:
    // impl() is private; only SteeringKernel (friend) may call it
    // to unwrap the FlowFieldServerImpl* during set_flow_field_server.
    FlowFieldServerImpl& impl() { return impl_; }
    FlowFieldServerImpl impl_;
};

} // namespace drossfront
