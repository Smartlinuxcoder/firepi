module uart_rx #(
    parameter CLK_FREQ = 50000000,
    parameter BAUD_RATE = 115200
) (
    input wire clk,
    input wire rx,
    output reg [7:0] data,
    output reg valid
);
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam IDLE = 0;
    localparam START = 1;
    localparam DATA = 2;
    localparam STOP = 3;

    reg [1:0] state = IDLE;
    reg [15:0] clk_count = 0;
    reg [2:0] bit_index = 0;

    always @(posedge clk) begin
        valid <= 0;
        case (state)
            IDLE: begin
                clk_count <= 0;
                bit_index <= 0;
                if (rx == 0) state <= START;
            end
            START: begin
                if (clk_count == (CLKS_PER_BIT / 2)) begin
                    if (rx == 0) begin
                        clk_count <= 0;
                        state <= DATA;
                    end else begin
                        state <= IDLE;
                    end
                end else begin
                    clk_count <= clk_count + 1;
                end
            end
            DATA: begin
                if (clk_count == CLKS_PER_BIT) begin
                    clk_count <= 0;
                    data[bit_index] <= rx;
                    if (bit_index == 7) begin
                        bit_index <= 0;
                        state <= STOP;
                    end else begin
                        bit_index <= bit_index + 1;
                    end
                end else begin
                    clk_count <= clk_count + 1;
                end
            end
            STOP: begin
                if (clk_count == CLKS_PER_BIT) begin
                    valid <= 1;
                    state <= IDLE;
                end else begin
                    clk_count <= clk_count + 1;
                end
            end
        endcase
    end
endmodule

module uart_tx #(
    parameter CLK_FREQ = 50000000,
    parameter BAUD_RATE = 115200
) (
    input wire clk,
    input wire start,
    input wire [7:0] data,
    output reg tx,
    output reg busy
);
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam IDLE = 0;
    localparam START = 1;
    localparam DATA = 2;
    localparam STOP = 3;

    reg [1:0] state = IDLE;
    reg [15:0] clk_count = 0;
    reg [2:0] bit_index = 0;
    reg [7:0] data_reg;

    initial tx = 1;

    always @(posedge clk) begin
        case (state)
            IDLE: begin
                tx <= 1;
                busy <= 0;
                if (start) begin
                    data_reg <= data;
                    state <= START;
                    busy <= 1;
                    clk_count <= 0;
                end
            end
            START: begin
                tx <= 0;
                if (clk_count == CLKS_PER_BIT) begin
                    clk_count <= 0;
                    state <= DATA;
                    bit_index <= 0;
                end else begin
                    clk_count <= clk_count + 1;
                end
            end
            DATA: begin
                tx <= data_reg[bit_index];
                if (clk_count == CLKS_PER_BIT) begin
                    clk_count <= 0;
                    if (bit_index == 7) begin
                        state <= STOP;
                    end else begin
                        bit_index <= bit_index + 1;
                    end
                end else begin
                    clk_count <= clk_count + 1;
                end
            end
            STOP: begin
                tx <= 1;
                if (clk_count == CLKS_PER_BIT) begin
                    state <= IDLE;
                    busy <= 0;
                end else begin
                    clk_count <= clk_count + 1;
                end
            end
        endcase
    end
endmodule
