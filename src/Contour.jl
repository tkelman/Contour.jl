module Contour

using ImmutableArrays

export ContourLevel, Curve2, contour, contours

type Curve2{T}
    vertices::Vector{Vector2{T}}
end
Curve2{T}(::Type{T}) = Curve2(Vector2{T}[])

type ContourLevel
    level::Float64
    lines::Vector{Curve2{Float64}}
end
ContourLevel(h::Float64) = ContourLevel(h, Curve2{Float64}[])
ContourLevel(h::Real) = ContourLevel(float64(h))

function contour(x, y, z, level::Number)
    # Todo: size checking on x,y,z
    trace_contour(x, y, z,level,get_level_cells(z,level))
end
contours(x,y,z,levels) = [contour(x,y,z,l) for l in levels]
function contours(x,y,z,Nlevels::Integer)
    zmin,zmax = extrema(z)
    dz = (zmax-zmin) / (Nlevels+1)
    levels = range(zmin+dz,dz,Nlevels)
    contours(x,y,z,levels)
end
contours(x,y,z) = contours(x,y,z,10)


# The marching squares algorithm defines 16 cell types
# based on the edges that a contour line enters and exits
# through. The vertices of cells are ordered as follows
# 4 +---+ 3
#   |   |
# 1 +---+ 2
# A contour line enters an edge with vertices v_i and
# v_j (counter-clockwise order) if z(v_i) <= h < z(v_j)
# and exits the edge if z(v_i) > h >= z(v_j).
# Each cell type is identified with 4 bits, with each
# bit corresponding to a vertex (MSB -> 4, LSB -> 1).
# A bit is set for vertex v_i is set if z(v_i) > h. So a cell
# where a contour line only enters from the left and exits
# through the top will have the cell type: 0b0111
# Note that there are two cases where there are two
# lines crossing through the same cell: 0b0101, 0b1010.
# In this implementation, we add four more cell types
# in order to propertly identify these ambigous cases.

function get_level_cells(z, h::Number)
    cells = Dict{(Int,Int),Int8}()
    xi_max, yi_max = size(z)

    local case::Int8

    for xi in 1:xi_max-1
        for yi in 1:yi_max-1
            case = 1(z[xi,yi] > h)     |
                   2(z[xi+1,yi] > h)   |
                   4(z[xi+1,yi+1] > h) |
                   8(z[xi,yi+1] > h)

            # Process ambigous cells (case 5 and 10) using
            # a bilinear interplotation of the cell-center value.
            # We add cases 16-19 to handle these cells
            if case != 0 && case != 15
                if case == 5
                    cells[(xi,yi)] = 16 + (0.25(z[xi,yi] + z[xi,yi+1] + z[xi+1,yi] + z[xi+1,yi+1]) > h)
                elseif case == 10
                    cells[(xi,yi)] = 18 + (0.25(z[xi,yi] + z[xi,yi+1] + z[xi+1,yi] + z[xi+1,yi+1]) > h)
                else
                    cells[(xi,yi)] = case
                end
            end
        end
    end

    return cells
end


# Some constants used by trace_contour

const lt, rt, up, dn = int8(1), int8(2), int8(3), int8(4)
const ccw, cw = int8(1), int8(2)

# Each row in the constants refer to a marching squares case,
# while each column correspond to a search direction.
# The exit_face LUT finds the edge where the contour leaves
# The dir_r/c constants points to the location of the next cell.
# col 1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16 17 18 19
const dir_y = int8(
    [-1 +0 +0 +1 +0 +1 +1 +0 -1 +0 +0 +0 -1 +0 +0 -1 +1 +0 +0;
     +0 -1 +0 +0 +0 -1 +0 +1 +1 +0 +1 +0 +0 -1 +0 +0 +0 +1 -1]')
const dir_x = int8(
    [+0 +1 +1 +0 +0 +0 +0 -1 +0 +0 +1 -1 +0 -1 +0 +0 +0 -1 -1;
     -1 +0 -1 +1 +0 +0 -1 +0 +0 +0 +0 +1 +1 +0 +0 -1 -1 +0 +0]')
const exit_face = int8(
    [dn rt rt up up up up lt dn dn rt lt dn lt lt dn up lt lt;
     lt dn lt rt rt dn lt up up up up rt rt dn dn lt lt up dn]')

function add_vertex!{T}(curve::Curve2{T}, pos::(T, T), dir::Int8)
    if dir == ccw
        push!(curve.vertices, Vector2{T}(pos...))
    else
        unshift!(curve.vertices, Vector2{T}(pos...))
    end
end

# Given the row and column indices of the lower left
# vertex, add the location where the contour level
# crosses the specified edge.
function interpolate{T<:FloatingPoint}(x, y, z::Matrix{T}, h::Number, xi::Int, yi::Int, edge::Int8)
    if edge == lt
        y_interp = y[yi] + (y[yi+1] - y[yi])*(h - z[xi,yi])/(z[xi,yi+1] - z[xi,yi])
        x_interp = x[xi]
    elseif edge == rt
        y_interp = y[yi] + (y[yi+1] - y[yi])*(h - z[xi+1,yi])/(z[xi+1,yi+1] - z[xi+1,yi])
        x_interp = x[xi + 1]
    elseif edge == up
        y_interp = y[yi + 1]
        x_interp = x[xi] + (x[xi+1] - x[xi])*(h - z[xi,yi+1])/(z[xi+1,yi+1] - z[xi,yi+1])
    elseif edge == dn
        y_interp = y[yi]
        x_interp = x[xi] + (x[xi+1] - x[xi])*(h - z[xi,yi])/(z[xi+1,yi] - z[xi,yi])
    end

    return x_interp, y_interp

end

# Given a starting cell and a search direction, keep adding
# contour crossing until we close the contour or hit a boundary
function chase(x, y, z, h, cells, xi, yi, xi_0, yi_0, xi_max, yi_max, dir::Int8, curve::Curve2)
    case = int8(0)
    while (xi,yi) != (xi_0,yi_0) && 0 < yi < yi_max && 0 < xi < xi_max
        case = cells[(xi,yi)]
        add_vertex!(curve, interpolate(x, y, z, h, xi, yi, exit_face[case,dir]), dir)
        if case == 16
            cells[(xi,yi)] = 4
        elseif case == 17
            cells[(xi,yi)] = 13
        elseif case == 18
            cells[(xi,yi)] = 2
        elseif case == 19
            cells[(xi,yi)] = 11
        else
            delete!(cells, (xi,yi))
        end
    (xi,yi) = (xi + dir_x[case,dir], yi + dir_y[case,dir])
end

return (xi,yi), case
end


function trace_contour(x, y, z, h::Number, cells::Dict{(Int,Int),Int8})

    contours = ContourLevel(h)

    local yi::Int
    local xi::Int
    local xi_0::Int
    local yi_0::Int

    local xi_max::Int
    local yi_max::Int

    (xi_max, yi_max) = size(z)

    # When tracing out contours, this algorithm picks an arbitrary
    # starting cell, then first follows the contour in the conouter
    # clockwise direction until it either ends up where it started
    # or at one of the boundaries.  It then tries to trace the contour
    # in the opposite direction.

    while length(cells) > 0
        case::Int8
        case0::Int8

        contour = Curve2(Float64)

        # Pick initial box
        (xi_0, yi_0), case0 = first(cells)
        (xi,yi) = (xi_0,yi_0)
        case = case0

        # Add the contour entry location for cell (xi_0,yi_0)
        add_vertex!(contour, interpolate(x, y, z, h, xi_0, yi_0, exit_face[case,cw]), cw)
        add_vertex!(contour, interpolate(x, y, z, h, xi_0, yi_0, exit_face[case,ccw]), ccw)
        (xi,yi) = (xi_0 + dir_x[case,ccw], yi_0 + dir_y[case,ccw])
        if case == 16
            cells[(xi_0,yi_0)] = 4
        elseif case == 17
            cells[(xi_0,yi_0)] = 13
        elseif case == 18
            cells[(xi_0,yi_0)] = 2
        elseif case == 19
            cells[(xi_0,yi_0)] = 11
        else
            delete!(cells, (xi_0,yi_0))
        end

        # Start trace in CCW direction
        (xi,yi), case = chase(x, y, z, h, cells, xi, yi, xi_0, yi_0, xi_max, yi_max, ccw, contour)

        # Add the contour exit location for cell (r0,c0)
        if (xi,yi) != (xi_0,yi_0)
            (xi,yi) = (xi_0 + dir_x[case0,cw], yi_0 + dir_y[case0,cw])
        end

        # Start trace in CW direction
        chase(x, y, z, h, cells, xi, yi, xi_0, yi_0, xi_max, yi_max, cw, contour)
        push!(contours.lines, contour)
    end

    return contours

end

end
