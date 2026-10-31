//! The units the calculator converts between ("10 km to mi"): each with
//! its names, its dimension, and how it relates to that dimension's base
//! unit.

const std = @import("std");

pub const Dimension = enum { length, mass, time, data, temperature, volume, speed, area };

pub const Unit = struct {
    names: []const []const u8,
    dimension: Dimension,
    /// Value in the base unit of `dimension` for 1 of this unit.
    factor: f64,
    /// Added after scaling (temperature only; base is kelvin).
    offset: f64 = 0,
};

const units = [_]Unit{
    // Lengths, in metres.
    .{
        .names = &.{ "mm", "millimeter", "millimeters", "millimetre" },
        .dimension = .length,
        .factor = 0.001,
    },
    .{
        .names = &.{ "cm", "centimeter", "centimeters", "centimetre" },
        .dimension = .length,
        .factor = 0.01,
    },
    .{ .names = &.{ "m", "meter", "meters", "metre", "metres" }, .dimension = .length, .factor = 1 },
    .{
        .names = &.{ "km", "kilometer", "kilometers", "kilometre" },
        .dimension = .length,
        .factor = 1000,
    },
    .{ .names = &.{ "in", "inch", "inches" }, .dimension = .length, .factor = 0.0254 },
    .{ .names = &.{ "ft", "foot", "feet" }, .dimension = .length, .factor = 0.3048 },
    .{ .names = &.{ "yd", "yard", "yards" }, .dimension = .length, .factor = 0.9144 },
    .{ .names = &.{ "mi", "mile", "miles" }, .dimension = .length, .factor = 1609.344 },
    // Masses, in kilograms.
    .{ .names = &.{ "mg", "milligram", "milligrams" }, .dimension = .mass, .factor = 1e-6 },
    .{ .names = &.{ "g", "gram", "grams" }, .dimension = .mass, .factor = 0.001 },
    .{ .names = &.{ "kg", "kilogram", "kilograms", "kilo", "kilos" }, .dimension = .mass, .factor = 1 },
    .{ .names = &.{ "t", "ton", "tons", "tonne", "tonnes" }, .dimension = .mass, .factor = 1000 },
    .{ .names = &.{ "oz", "ounce", "ounces" }, .dimension = .mass, .factor = 0.028349523125 },
    .{ .names = &.{ "lb", "lbs", "pound", "pounds" }, .dimension = .mass, .factor = 0.45359237 },
    // Times, in seconds.
    .{ .names = &.{ "ms", "millisecond", "milliseconds" }, .dimension = .time, .factor = 0.001 },
    .{ .names = &.{ "s", "sec", "second", "seconds" }, .dimension = .time, .factor = 1 },
    .{ .names = &.{ "min", "minute", "minutes" }, .dimension = .time, .factor = 60 },
    .{ .names = &.{ "h", "hr", "hour", "hours" }, .dimension = .time, .factor = 3600 },
    .{ .names = &.{ "d", "day", "days" }, .dimension = .time, .factor = 86400 },
    .{ .names = &.{ "wk", "week", "weeks" }, .dimension = .time, .factor = 604800 },
    .{ .names = &.{ "yr", "year", "years" }, .dimension = .time, .factor = 31557600 },
    // Data sizes, in bytes. The multiples are binary, as file managers show them.
    .{ .names = &.{ "b", "byte", "bytes" }, .dimension = .data, .factor = 1 },
    .{ .names = &.{ "kb", "kib", "kilobyte", "kilobytes" }, .dimension = .data, .factor = 1024 },
    .{ .names = &.{ "mb", "mib", "megabyte", "megabytes" }, .dimension = .data, .factor = 1024 * 1024 },
    .{
        .names = &.{ "gb", "gib", "gigabyte", "gigabytes" },
        .dimension = .data,
        .factor = 1024 * 1024 * 1024,
    },
    .{
        .names = &.{ "tb", "tib", "terabyte", "terabytes" },
        .dimension = .data,
        .factor = 1024 * 1024 * 1024 * 1024,
    },
    // Temperatures, in kelvin.
    .{ .names = &.{ "c", "celsius", "°c" }, .dimension = .temperature, .factor = 1, .offset = 273.15 },
    .{
        .names = &.{ "f", "fahrenheit", "°f" },
        .dimension = .temperature,
        .factor = 5.0 / 9.0,
        .offset = 273.15 - 32.0 * 5.0 / 9.0,
    },
    .{ .names = &.{ "k", "kelvin" }, .dimension = .temperature, .factor = 1 },
    // Volumes, in litres.
    .{
        .names = &.{ "ml", "milliliter", "milliliters", "millilitre" },
        .dimension = .volume,
        .factor = 0.001,
    },
    .{ .names = &.{ "l", "liter", "liters", "litre", "litres" }, .dimension = .volume, .factor = 1 },
    .{ .names = &.{ "gal", "gallon", "gallons" }, .dimension = .volume, .factor = 3.785411784 },
    .{ .names = &.{ "cup", "cups" }, .dimension = .volume, .factor = 0.2365882365 },
    .{ .names = &.{ "floz", "fl oz" }, .dimension = .volume, .factor = 0.0295735295625 },
    // Speeds, in metres per second.
    .{ .names = &.{ "kmh", "km/h", "kph" }, .dimension = .speed, .factor = 1000.0 / 3600.0 },
    .{ .names = &.{"mph"}, .dimension = .speed, .factor = 0.44704 },
    .{ .names = &.{ "m/s", "mps" }, .dimension = .speed, .factor = 1 },
    .{ .names = &.{ "kn", "knot", "knots" }, .dimension = .speed, .factor = 0.514444 },
    // Areas, in square metres.
    .{ .names = &.{ "m2", "sqm" }, .dimension = .area, .factor = 1 },
    .{ .names = &.{ "km2", "sqkm" }, .dimension = .area, .factor = 1e6 },
    .{ .names = &.{ "ft2", "sqft" }, .dimension = .area, .factor = 0.09290304 },
    .{ .names = &.{ "ha", "hectare", "hectares" }, .dimension = .area, .factor = 10000 },
    .{ .names = &.{ "acre", "acres" }, .dimension = .area, .factor = 4046.8564224 },
};

/// The unit called `name`, in any case ("KM", "Miles"), or null.
pub fn find(name: []const u8) ?*const Unit {
    for (&units) |*unit| {
        for (unit.names) |unit_name| {
            if (std.ascii.eqlIgnoreCase(unit_name, name)) return unit;
        }
    }
    return null;
}
