<?php

// format time into N years/months/weeks/days ago
if ( ! function_exists('time_ago')) {
    function time_ago($time, $now=null)
    {
        $now = $now ? (new Datetime($now)) : (new Datetime);
        $time = new Datetime($time);
        $diff = $now->diff($time);

        $units = [
            '年前'   => 'y',
            '月前'   => 'm',
            '周前'   => 'w',
            '天前'   => 'd',
            '小时前' => 'h',
            '分钟前' => 'i',
            '秒前'   => 's',
        ];

        foreach ($units as $unit => $k) {
            if (@$diff->$k) {
                return $diff->$k . $unit;
            }
        }
    }
}


// compare two timestamp like `strcmp`
if ( ! function_exists('time_compare')) {
    function time_compare($time, $time_str)
    {
        $to_timestamp = function ($time) {
            return is_string($time) ? strtotime($time) : (int)$time;
        };

        return $to_timestamp($time) - $to_timestamp($time_str);
    }
}
