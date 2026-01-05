#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["igraph", "leidenalg"]
# ///
"""
Leiden community detection using Python leidenalg.

Reads graph edges from stdin as JSON, outputs communities as JSON.
True Leiden algorithm with refinement phase - should complete in <1 second
for graphs with 15k entities.

Usage:
    echo '{"edges": [[0,1], [1,2]], "resolution": 1.0}' | uv run leidenalg_detect.py
"""

import json
import sys
from typing import Any

import igraph as ig
import leidenalg as la


def detect_communities(
    edges: list[tuple[str, str, float]],
    resolution: float = 1.0,
    n_iterations: int = -1,
) -> list[dict[str, Any]]:
    """
    Detect communities using Leiden algorithm.

    Args:
        edges: List of (source_id, target_id, weight) tuples
        resolution: Higher = smaller communities (default 1.0)
        n_iterations: -1 for convergence, positive for fixed iterations

    Returns:
        List of community dicts with 'level' and 'entity_ids'
    """
    if not edges:
        return []

    # Build graph from edges
    # igraph needs numeric vertex IDs, so we map string IDs
    vertex_ids: dict[str, int] = {}
    edge_tuples: list[tuple[int, int]] = []
    weights: list[float] = []

    for source, target, weight in edges:
        if source not in vertex_ids:
            vertex_ids[source] = len(vertex_ids)
        if target not in vertex_ids:
            vertex_ids[target] = len(vertex_ids)
        edge_tuples.append((vertex_ids[source], vertex_ids[target]))
        weights.append(weight)

    # Reverse mapping for output
    id_to_vertex = {v: k for k, v in vertex_ids.items()}

    # Create igraph Graph
    g = ig.Graph(n=len(vertex_ids), edges=edge_tuples, directed=False)
    g.es["weight"] = weights

    # Run Leiden with Modularity optimization
    partition = la.find_partition(
        g,
        la.RBConfigurationVertexPartition,
        weights=weights,
        resolution_parameter=resolution,
        n_iterations=n_iterations,
    )

    # Group vertices by community
    communities_by_id: dict[int, list[str]] = {}
    for vertex_idx, community_id in enumerate(partition.membership):
        if community_id not in communities_by_id:
            communities_by_id[community_id] = []
        communities_by_id[community_id].append(id_to_vertex[vertex_idx])

    # Format output (single level for now)
    communities = [
        {"level": 0, "entity_ids": entity_ids}
        for entity_ids in communities_by_id.values()
    ]

    return communities


def main():
    # Read input from stdin
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": f"Invalid JSON input: {e}"}), file=sys.stderr)
        sys.exit(1)

    edges = input_data.get("edges", [])
    resolution = input_data.get("resolution", 1.0)
    n_iterations = input_data.get("n_iterations", -1)

    # Convert edges to tuples with weights
    edge_tuples = []
    for edge in edges:
        if len(edge) == 2:
            source, target = edge
            weight = 1.0
        else:
            source, target, weight = edge
        edge_tuples.append((source, target, float(weight or 1.0)))

    try:
        communities = detect_communities(
            edge_tuples,
            resolution=resolution,
            n_iterations=n_iterations,
        )

        result = {
            "communities": communities,
            "stats": {
                "vertex_count": len(set(v for e in edge_tuples for v in e[:2])),
                "edge_count": len(edge_tuples),
                "community_count": len(communities),
            }
        }
        print(json.dumps(result))

    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
