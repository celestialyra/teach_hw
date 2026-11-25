/*
 * Copyright (c) 2024 Tiny Tapeout LTD
 * SPDX-License-Identifier: Apache-2.0
 * Snake Game for Tiny Tapeout VGA + Gamepad Pmod
 */

`default_nettype none

module tt_um_vga_example (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

    // VGA signals
    wire hsync;
    wire vsync;
    wire [1:0] R;
    wire [1:0] G;
    wire [1:0] B;
    wire video_active;
    wire [9:0] pix_x;
    wire [9:0] pix_y;

    // TinyVGA PMOD
    assign uo_out = {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]};

    // Unused outputs assigned to 0
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    // Suppress unused signals warning (ui_in[6:4] are used by gamepad)
    wire _unused_ok = &{ena, ui_in[7], ui_in[3:0], uio_in, pix_x[3:0], pix_y[9], pix_y[3:0]};

    hvsync_generator vga_sync_gen (
        .clk(clk),
        .reset(~rst_n),
        .hsync(hsync),
        .vsync(vsync),
        .display_on(video_active),
        .hpos(pix_x),
        .vpos(pix_y)
    );

    // Gamepad Pmod
    wire inp_b, inp_y, inp_select, inp_start, inp_up, inp_down, inp_left, inp_right, inp_a, inp_x, inp_l, inp_r;

    gamepad_pmod_single driver (
        // Inputs:
        .rst_n(rst_n),
        .clk(clk),
        .pmod_data(ui_in[6]),
        .pmod_clk(ui_in[5]),
        .pmod_latch(ui_in[4]),
        // Outputs:
        .b(inp_b),
        .y(inp_y),
        .select(inp_select),
        .start(inp_start),
        .up(inp_up),
        .down(inp_down),
        .left(inp_left),
        .right(inp_right),
        .a(inp_a),
        .x(inp_x),
        .l(inp_l),
        .r(inp_r)
    );

    wire _unused_gamepad = &{inp_b, inp_y, inp_select, inp_a, inp_x, inp_l, inp_r};

    // Grid parameters (640x480 divided by 16x16 tiles = 40x30 grid)
    localparam GRID_W     = 6'd40;
    localparam GRID_H     = 5'd30;
    localparam MAX_LEN    = 32;
    localparam MOVE_DELAY = 4'd4;

    // Directions
    localparam DIR_RIGHT = 2'd0;
    localparam DIR_DOWN  = 2'd1;
    localparam DIR_LEFT  = 2'd2;
    localparam DIR_UP    = 2'd3;

    // Game states
    localparam NEW_GAME  = 2'd0;
    localparam PLAY      = 2'd1;
    localparam GAME_OVER = 2'd2;

    reg [1:0] state;
    reg [1:0] dir;
    reg [1:0] next_dir;
    reg [3:0] move_timer;

    //snake body and apple registers
    reg [5:0] snake_x [0:MAX_LEN-1];
    reg [4:0] snake_y [0:MAX_LEN-1];
    reg [5:0] length;
    reg [5:0] apple_x;
    reg [4:0] apple_y;

    //LFSR pseudo-random apple coordinates
    reg [15:0] lfsr;
    wire lfsr_feedback = lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            lfsr <= 16'hACE1;
        else
            lfsr <= {lfsr[14:0], lfsr_feedback};
    end

    //random coordinates within 40x30 bounds
    wire [5:0] rand_x = (lfsr[5:0] >= GRID_W) ? (lfsr[5:0] - GRID_W) : lfsr[5:0];
    wire [4:0] rand_y = (lfsr[10:6] >= GRID_H) ? (lfsr[10:6] - GRID_H) : lfsr[10:6];

    //next head position logic
    reg [5:0] next_head_x;
    reg [4:0] next_head_y;

    always @(*) begin
        next_head_x = snake_x[0];
        next_head_y = snake_y[0];
        case (next_dir)
            DIR_RIGHT: next_head_x = snake_x[0] + 6'd1;
            DIR_DOWN:  next_head_y = snake_y[0] + 5'd1;
            DIR_LEFT:  next_head_x = snake_x[0] - 6'd1;
            DIR_UP:    next_head_y = snake_y[0] - 5'd1;
        endcase
    end

    //collision detection
    wire hit_wall = (next_head_x >= GRID_W) || (next_head_y >= GRID_H);
    wire ate_apple = (next_head_x == apple_x) && (next_head_y == apple_y);

    reg hit_self;
    integer j;
    always @(*) begin
        hit_self = 1'b0;
        for (j = 1; j < MAX_LEN; j = j + 1) begin
            if ((j < length) && (next_head_x == snake_x[j]) && (next_head_y == snake_y[j]))
                hit_self = 1'b1;
        end
    end

    integer i;
    always @(posedge vsync or negedge rst_n) begin
        if (!rst_n) begin
            state <= NEW_GAME;
        end else begin
            case (state)
                NEW_GAME: begin
                    length     <= 6'd3;
                    dir        <= DIR_RIGHT;
                    next_dir   <= DIR_RIGHT;
                    move_timer <= 4'd0;

                    //initial snake position
                    snake_x[0] <= 6'd10; snake_y[0] <= 5'd15;
                    snake_x[1] <= 6'd9;  snake_y[1] <= 5'd15;
                    snake_x[2] <= 6'd8;  snake_y[2] <= 5'd15;
                    for (i = 3; i < MAX_LEN; i = i + 1) begin
                        snake_x[i] <= 6'd0;
                        snake_y[i] <= 5'd0;
                    end

                    //initial apple position
                    apple_x <= 6'd25;
                    apple_y <= 5'd15;

                    state <= PLAY;
                end

                PLAY: begin
                    //prevent 180-degree reversals
                    if (inp_up && dir != DIR_DOWN)
                        next_dir <= DIR_UP;
                    else if (inp_down && dir != DIR_UP)
                        next_dir <= DIR_DOWN;
                    else if (inp_left && dir != DIR_RIGHT)
                        next_dir <= DIR_LEFT;
                    else if (inp_right && dir != DIR_LEFT)
                        next_dir <= DIR_RIGHT;

                    //advance snake on movement tick
                    if (move_timer == MOVE_DELAY) begin
                        move_timer <= 4'd0;
                        dir <= next_dir;

                        if (hit_wall || hit_self) begin
                            state <= GAME_OVER;
                        end else begin
                            //shift body segments
                            for (i = MAX_LEN - 1; i > 0; i = i - 1) begin
                                snake_x[i] <= snake_x[i - 1];
                                snake_y[i] <= snake_y[i - 1];
                            end
                            snake_x[0] <= next_head_x;
                            snake_y[0] <= next_head_y;

                            //apple consumption
                            if (ate_apple) begin
                                if (length < MAX_LEN)
                                    length <= length + 6'd1;
                                apple_x <= rand_x;
                                apple_y <= rand_y;
                            end
                        end
                    end else begin
                        move_timer <= move_timer + 4'd1;
                    end

                    if (inp_start)
                        state <= NEW_GAME;
                end

                GAME_OVER: begin
                    if (inp_start)
                        state <= NEW_GAME;
                end

                default: state <= NEW_GAME;
            endcase
        end
    end

    wire [5:0] grid_x = pix_x[9:4];
    wire [4:0] grid_y = pix_y[8:4];

    reg is_snake;
    reg is_head;
    integer k;
    always @(*) begin
        is_snake = 1'b0;
        is_head  = (grid_x == snake_x[0]) && (grid_y == snake_y[0]);
        for (k = 1; k < MAX_LEN; k = k + 1) begin
            if ((k < length) && (grid_x == snake_x[k]) && (grid_y == snake_y[k]))
                is_snake = 1'b1;
        end
    end

    wire is_apple = (grid_x == apple_x) && (grid_y == apple_y);

    wire is_tile_edge = (pix_x[3:0] == 4'd0) || (pix_y[3:0] == 4'd0);

    reg [5:0] color;
    always @(*) begin
        if (state == GAME_OVER && (is_head || is_snake)) begin
            color = 6'b110000; //red snake on game over
        end else if (is_head) begin
            color = is_tile_edge ? 6'b001000 : 6'b011101; //snake
        end else if (is_snake) begin
            color = is_tile_edge ? 6'b000100 : 6'b001100; //snake body
        end else if (is_apple) begin
            color = is_tile_edge ? 6'b000000 : 6'b110000; //apple
        end else begin
            color = 6'b000000; //black bg
        end
    end

    assign R = video_active ? color[5:4] : 2'b00;
    assign G = video_active ? color[3:2] : 2'b00;
    assign B = video_active ? color[1:0] : 2'b00;

endmodule
