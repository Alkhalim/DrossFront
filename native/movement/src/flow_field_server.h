#pragma once
#include <memory>
#include <unordered_map>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include "types.h"
#include "cost_grid.h"
#include "flow_field.h"

namespace drossfront {

class FlowFieldServer : public godot::Object {
    GDCLASS(FlowFieldServer, godot::Object)

protected:
    static void _bind_methods();

public:
    FlowFieldServer();
    ~FlowFieldServer();

    // Map setup (called from GDScript at scene start).
    void configure_map(int grid_w, int grid_h, float cell_size,
                       float origin_x, float origin_z);

    // Per-class agent radius for dilation (set once at scene start).
    void set_agent_radius(int agent_class, float radius);

    // GDScript-facing API.
    FieldId build_field(godot::Vector3 goal, int agent_class);
    void release_field(FieldId id);
    godot::Vector2 sample(FieldId id, godot::Vector3 world_pos);
    void mark_obstacle(godot::AABB aabb, bool blocked);
    void mark_soft_cost(godot::AABB aabb, int cost);

    // Y-aware Dijkstra support: writes a per-cell navmesh elevation into
    // every per-class CostGrid (terrain Y is shared across agent classes)
    // so the field's neighbor expansion can reject cliffs while allowing
    // ramps. Caller (GDScript bootstrap) populates this once per scene
    // start by sweeping NavigationServer3D.map_get_closest_point per
    // cell and feeding the closest-point Y back here.
    void set_cell_y_at(godot::Vector3 world_pos, float y);

    // Diagnostics.
    int field_count() const { return static_cast<int>(fields_.size()); }
    bool field_exists(FieldId id) const { return fields_.count(id) > 0; }

private:
    int grid_w_ = 0;
    int grid_h_ = 0;
    float cell_size_ = 1.0f;
    float origin_x_ = 0.0f;
    float origin_z_ = 0.0f;
    float agent_radii_[AGENT_CLASS_COUNT] = {0.6f, 1.0f, 2.0f};

    std::unique_ptr<CostGrid> cost_grids_[AGENT_CLASS_COUNT];

    struct FieldEntry {
        std::unique_ptr<FlowField> field;
        int agent_class;
        int goal_cell;
        bool dirty;
    };
    std::unordered_map<FieldId, FieldEntry> fields_;
    FieldId next_field_id_ = 1;

    void rebuild_field(FieldEntry &entry);
};

} // namespace drossfront
