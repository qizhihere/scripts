if ( ! function_exists('time_ago')) {
    function time_ago($timestamp, $lang='cn')
    {
        $msg = [
            'cn' => [
                'day' => '天前',
                'hour' => '小时前',
                'minute' => '分钟前',
                'second' => '秒前',
            ],
            'en' => [
                'day' => ' days ago',
                'hour' => ' hours ago',
                'minute' => ' minutes ago',
                'second' => ' seconds ago',
            ]
        ];

        // convert to timestamp
        if (is_string($timestamp)) {
            $timestamp = strtotime($timestamp);
        }

        $now = time();
        $interval = $now - $timestamp;

        $days = intval($interval / (24 * 3600));
        if ($days > 0) {
            return $days . $msg[$lang]['day'];
        }

        $hours = intval($interval / 3600);
        if ($hours > 0) {
            return $hours . $msg[$lang]['hour'];
        }

        $minutes = intval($interval / 60);
        if ($minutes > 0) {
            return $minutes . $msg[$lang]['minute'];
        }

        return $interval. $msg[$lang]['second'];
    }
}