module top (
    input clk_50mhz,
    output led_out
);

    reg [25:0] counter;

    always @(posedge clk_50mhz) begin
        counter <= counter + 1;
    end

    assign led_out = counter[25];

endmodule
