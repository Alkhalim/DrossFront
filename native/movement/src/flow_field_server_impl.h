#pragma once
#include <memory>
#include <unordered_map>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include "types.h"
#include "cost_grid.h"
#include "flow_field.h"

namespace drossfront {

class FlowFieldServerImpl {
public:
    FlowFieldServerImpl();
    ~FlowFieldServerImpl();

    // Map setup (called from GDScript at scene start).
    void configure_map(int grid_w, int grid_h, float cell_size,
                       float origin_x, float origin_z);

    // Per-class agent radius for dilation (set once at scene start).
    void set_agent_radius(int agent_class, float radius);

    FieldId build_field(godot::Vector3 goal, int agent_class);
    void release_field(FieldId id);
    godot::Vector2 sample(FieldId id, godot::Vector3 world_pos);
    void mark_obstacle(godot::AABB aabb, bool blocked);
    void mark_soft_cost(godot::AABB aabb, int cost);
    void set_cell_y_at(godot::Vector3 world_pos, float y);

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
        // Refcount of GDScript-side handles holding this field. build_field
        // increments on cache hit, release_field decrements; field is
        // destroyed when refcount hits 0. Lets multiple units sharing
        // (goal_cell, agent_class) reuse a single Dijkstra build instead
        // of each rebuilding the same ~25k-cell graph.
        int refcount;
    };
    std::unordered_map<FieldId, FieldEntry> fields_;
    // Cache key = (goal_cell << 32) | agent_class. Maps a goal+class pair to
    // its currently-live FieldId so build_field can short-circuit a Dijkstra
    // rebuild when the same goal is requested by another agent.
    std::unordered_map<uint64_t, FieldId> cache_key_to_id_;
    FieldId next_field_id_ = 1;

    static uint64_t cache_key_for(int goal_cell, int agent_class) {
        return (static_cast<uint64_t>(static_cast<uint32_t>(goal_cell)) << 32)
               | static_cast<uint32_t>(agent_class);
    }

    void rebuild_field(FieldEntry &entry);
};

} // namespace drossfront
