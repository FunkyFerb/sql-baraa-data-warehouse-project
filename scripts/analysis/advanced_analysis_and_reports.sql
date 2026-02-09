-- ===============================================================================
-- Change over time analysis
-- ===============================================================================
-- Analyse sales performance over time
-- Quick Date Functions
SELECT
    YEAR(order_date) AS order_year,
    MONTH(order_date) AS order_month,
    SUM(sales_amount) AS total_sales,
    COUNT(DISTINCT customer_key) AS total_customers,
    SUM(quantity) AS total_quantity
FROM gold.fact_sales
WHERE order_date IS NOT NULL
GROUP BY YEAR(order_date), MONTH(order_date)
ORDER BY YEAR(order_date), MONTH(order_date);

-- DATETRUNC()
SELECT
    DATETRUNC(month, order_date) AS order_date,
    SUM(sales_amount) AS total_sales,
    COUNT(DISTINCT customer_key) AS total_customers,
    SUM(quantity) AS total_quantity
FROM gold.fact_sales
WHERE order_date IS NOT NULL
GROUP BY DATETRUNC(month, order_date)
ORDER BY DATETRUNC(month, order_date);

-- FORMAT()
SELECT
    FORMAT(order_date, 'yyyy-MMM') AS order_date,
    SUM(sales_amount) AS total_sales,
    COUNT(DISTINCT customer_key) AS total_customers,
    SUM(quantity) AS total_quantity
FROM gold.fact_sales
WHERE order_date IS NOT NULL
GROUP BY FORMAT(order_date, 'yyyy-MMM')
ORDER BY FORMAT(order_date, 'yyyy-MMM');


-- ===============================================================================
-- Cumulative analysis
-- ===============================================================================
-- Claculate the total sales per month and the running toal of sales over time
SELECT
    order_date,
    total_sales,
    SUM(total_sales) OVER (PARTITION BY order_date ORDER BY order_date) AS running_total_sales,
    AVG(avg_price) OVER (PARTITION BY order_date ORDER BY order_date) AS moving_average_price
FROM (
    SELECT
        DATETRUNC(MONTH, order_date) AS order_date,
        SUM(sales_amount) AS total_sales,
        AVG(price) AS avg_price
    FROM gold.fact_sales
    WHERE order_date IS NOT NULL
    GROUP BY DATETRUNC(MONTH, order_date)
 )t;


-- ===============================================================================
-- Performance analysis
-- ===============================================================================
-- Analyze the yearly performance of products by comparing their sales to both the average sales performance of the product and the previous year's sales
WITH yearly_product_sales AS (
    SELECT
        YEAR(s.order_date) AS order_year,
        p.product_name,
        SUM(s.sales_amount) AS current_sales
    FROM gold.fact_sales AS s
    LEFT JOIN gold.dim_products as p
    ON s.product_key = p.product_key
    WHERE YEAR(s.order_date) IS NOT NULL
    GROUP BY YEAR(s.order_date),p.product_name
)
SELECT 
    order_year,
    product_name,
    current_sales,
    AVG(current_sales) OVER (PARTITION BY product_name) AS avg_sales,
    current_sales - AVG(current_sales) OVER (PARTITION BY product_name) AS diff_sales,
    CASE WHEN current_sales - AVG(current_sales) OVER (PARTITION BY product_name) > 0 THEN 'Above Avg'
         WHEN current_sales - AVG(current_sales) OVER (PARTITION BY product_name) < 0 THEN 'Below Avg'
         ELSE 'Avg'
    END avg_change,
    LAG(current_sales) OVER (PARTITION BY product_name ORDER BY order_year ASC) AS py_sales,
    current_sales - LAG(current_sales) OVER (PARTITION BY product_name ORDER BY order_year ASC) AS diff_py,
    CASE WHEN current_sales - LAG(current_sales) OVER (PARTITION BY product_name ORDER BY order_year ASC) > 0 THEN 'Increase'
         WHEN current_sales - LAG(current_sales) OVER (PARTITION BY product_name ORDER BY order_year ASC) < 0 THEN 'Decrease'
         ELSE 'No Change'
    END AS py_change
FROM yearly_product_sales
ORDER BY product_name, order_year;


-- ===============================================================================
-- Part to whole analysis
-- ===============================================================================
-- Which categories contribute the most to overall sales
WITH category_sales AS (
    SELECT
        category,
        SUM(sales_amount) AS total_sales
    FROM gold.fact_sales AS s
    LEFT JOIN gold.dim_products AS p
    ON s.product_key = p.product_key
    GROUP BY category
)
SELECT 
    category,
    total_sales,
    SUM(total_sales) OVER () AS overall_sales,
    CONCAT(ROUND((CAST(total_sales AS FLOAT) / SUM(total_sales) OVER ()) * 100, 2), '%') AS pct_of_total
FROM category_sales
ORDER BY total_sales DESC;


-- ===============================================================================
-- Data segmentation
-- ===============================================================================
-- Segment products into cost ranges and count how many products fall into each segment
WITH product_segments AS (
    SELECT
        product_key,
        product_name,
        cost,
        CASE WHEN cost < 100 THEN 'Bleow 100'
             WHEN cost BETWEEN 100 AND 500 THEN '100-500'
             WHEN cost BETWEEN 500 AND 1000 THEN '500-1000'
             ELSE 'Above 100'
        END cost_range
    FROM gold.dim_products
)
SELECT 
    cost_range,
    COUNT(product_key) AS total_products
FROM product_segments
GROUP BY cost_range
ORDER BY total_products DESC;

/*Group customers into three segments based on their spending behavior:
	- VIP: Customers with at least 12 months of history and spending more than €5,000.
	- Regular: Customers with at least 12 months of history but spending €5,000 or less.
	- New: Customers with a lifespan less than 12 months.
And find the total number of customers by each group
*/
WITH customer_spending AS (
    SELECT
        c.customer_key,
        SUM(s.sales_amount) AS total_spending,
        MIN(order_date) AS first_order,
        MAX(order_date) AS last_order,
        DATEDIFF(month, MIN(order_date), MAX(order_date)) AS lifespan
    FROM gold.fact_sales AS s
    LEFT JOIN gold.dim_customers AS c
    ON s.customer_key = c.customer_key
    GROUP BY c.customer_key
)
SELECT
    customer_segment,
    COUNT(customer_key) AS total_customers
FROM (
    SELECT
        customer_key,
        CASE WHEN lifespan >= 12 AND total_spending > 5000 THEN 'VIP'
             WHEN lifespan >= 12 AND total_spending <= 5000 THEN 'Regular'
             ELSE 'New'
        END customer_segment
    FROM customer_spending
)t
GROUP BY customer_segment
ORDER BY total_customers DESC;


-- ===============================================================================
-- Reporting
-- ===============================================================================
/*
Customer Report:
Purpose:
    - This report consolidates key customer metrics and behaviors

Highlights:
    1. Gathers essential fields such as names, ages, and transaction details.
	2. Segments customers into categories (VIP, Regular, New) and age groups.
    3. Aggregates customer-level metrics:
	   - total orders
	   - total sales
	   - total quantity purchased
	   - total products
	   - lifespan (in months)
    4. Calculates valuable KPIs:
	    - recency (months since last order)
		- average order value
		- average monthly spend
*/
IF OBJECT_ID('gold.report_customers', 'V') IS NOT NULL
    DROP VIEW gold.report_customers;
GO

CREATE VIEW gold.report_customers AS
WITH base_query AS (
    SELECT
        s.order_number,
        s.product_key,
        s.order_date,
        s.sales_amount,
        s.quantity,
        c.customer_key,
        c.customer_number,
        CONCAT(c.first_name, ' ', c.last_name) AS customer_name,
        DATEDIFF(YEAR, c.birthdate, GETDATE()) AS age
    FROM gold.fact_sales AS s
    LEFT JOIN gold.dim_customers AS c
    ON s.customer_key = c.customer_key
    WHERE order_date IS NOT NULL
)
, customer_aggregation AS (
    SELECT 
        customer_key,
        customer_number,
        customer_name,
        age,
        COUNT(DISTINCT order_number) AS total_orders,
        SUM(sales_amount) AS total_sales,
        SUM(quantity) AS total_quantity,
        COUNT(DISTINCT product_key) AS total_products,
        MAX(order_date) AS last_order,
        DATEDIFF(MONTH, MIN(order_date), MAX(order_date)) AS lifespan
    FROM base_query
    GROUP BY 
        customer_key,
        customer_number,
        customer_name,
        age
)
SELECT
    customer_key,
    customer_number,
    customer_name,
    age,
    CASE WHEN age < 20 THEN 'Under 20'
         When age BETWEEN 20 AND 39 THEN '20-39'
         When age BETWEEN 40 AND 49 THEN '40-49'
         ELSE '50 and above'
    END AS age_group,
    CASE WHEN lifespan >= 12 AND total_sales > 5000 THEN 'VIP'
         WHEN lifespan >= 12 AND total_sales <= 5000 THEN 'Regular'
         ELSE 'New'
    END customer_segment,
    last_order,
    DATEDIFF(MONTH, last_order, GETDATE()) AS recency,
    total_orders,
    total_sales,
    total_quantity,
    total_products,
    lifespan,
    CASE WHEN total_orders = 0 THEN 0
         ELSE total_sales / total_orders
    END AS avg_order_value,
    CASE WHEN lifespan = 0 THEN total_sales
         ELSE total_sales / lifespan
    END AS avg_monthly_spend
FROM customer_aggregation;

/*
Product Report:
Purpose:
    - This report consolidates key product metrics and behaviors.

Highlights:
    1. Gathers essential fields such as product name, category, subcategory, and cost.
    2. Segments products by revenue to identify High-Performers, Mid-Range, or Low-Performers.
    3. Aggregates product-level metrics:
       - total orders
       - total sales
       - total quantity sold
       - total customers (unique)
       - lifespan (in months)
    4. Calculates valuable KPIs:
       - recency (months since last sale)
       - average order revenue (AOR)
       - average monthly revenue
*/
IF OBJECT_ID('gold.report_products', 'V') IS NOT NULL
    DROP VIEW gold.report_products;
GO

CREATE VIEW gold.report_products AS
WITH base_query AS (
    SELECT
	      s.order_number,
        s.order_date,
		    s.customer_key,
        f.sales_amount,
        s.quantity,
        p.product_key,
        p.product_name,
        p.category,
        p.subcategory,
        p.cost
    FROM gold.fact_sales s
    LEFT JOIN gold.dim_products p
        ON s.product_key = p.product_key
    WHERE order_date IS NOT NULL  
)
, product_aggregations AS (
SELECT
    product_key,
    product_name,
    category,
    subcategory,
    cost,
    DATEDIFF(MONTH, MIN(order_date), MAX(order_date)) AS lifespan,
    MAX(order_date) AS last_sale_date,
    COUNT(DISTINCT order_number) AS total_orders,
	  COUNT(DISTINCT customer_key) AS total_customers,
    SUM(sales_amount) AS total_sales,
    SUM(quantity) AS total_quantity,
	ROUND(AVG(CAST(sales_amount AS FLOAT) / NULLIF(quantity, 0)),1) AS avg_selling_price
FROM base_query
GROUP BY
    product_key,
    product_name,
    category,
    subcategory,
    cost
)
SELECT 
	product_key,
	product_name,
	category,
	subcategory,
	cost,
	last_sale_date,
	DATEDIFF(MONTH, last_sale_date, GETDATE()) AS recency_in_months,
	CASE
		WHEN total_sales > 50000 THEN 'High-Performer'
		WHEN total_sales >= 10000 THEN 'Mid-Range'
		ELSE 'Low-Performer'
	END AS product_segment,
	lifespan,
	total_orders,
	total_sales,
	total_quantity,
	total_customers,
	avg_selling_price,
	CASE 
		WHEN total_orders = 0 THEN 0
		ELSE total_sales / total_orders
	END AS avg_order_revenue,
	CASE
		WHEN lifespan = 0 THEN total_sales
		ELSE total_sales / lifespan
	END AS avg_monthly_revenue
FROM product_aggregations; 
